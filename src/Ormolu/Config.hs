{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Configuration options used by the tool.
module Ormolu.Config
  ( Config (..),
    ColorMode (..),
    RegionIndices (..),
    RegionDeltas (..),
    SourceType (..),
    defaultConfig,
    regionIndicesToDeltas,
    DynOption (..),
    dynOptionToLocatedStr,

    -- * Fourmolu configuration
    PrinterOpts (..),
    PrinterOptsPartial,
    PrinterOptsTotal,
    defaultPrinterOpts,
    fillMissingPrinterOpts,
    CommaStyle (..),
    HaddockPrintStyle (..),

    -- ** Loading Fourmolu configuration
    loadConfigFile,
    configFileName,
    FourmoluConfig (..),
    ConfigFileLoadResult (..),
  )
where

import Data.Aeson ((.!=), (.:?))
import qualified Data.Aeson as Aeson
import Data.Char (isLower)
import Data.Functor.Identity (Identity (..))
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Yaml as Yaml
import GHC.Generics (Generic)
import qualified GHC.Types.SrcLoc as GHC
import Ormolu.Fixity (FixityMap)
import Ormolu.Fixity.Parser (parseFixityDeclaration)
import Ormolu.Terminal (ColorMode (..))
import System.Directory
  ( XdgDirectory (XdgConfig),
    findFile,
    getXdgDirectory,
    makeAbsolute,
  )
import System.FilePath (splitPath, (</>))
import Text.Megaparsec (errorBundlePretty)

-- | Type of sources that can be formatted by Ormolu.
data SourceType
  = -- | Consider the input as a regular Haskell module
    ModuleSource
  | -- | Consider the input as a Backpack module signature
    SignatureSource
  deriving (Eq, Show)

-- | Ormolu configuration.
data Config region = Config
  { -- | Dynamic options to pass to GHC parser
    cfgDynOptions :: ![DynOption],
    -- | Fixity overrides
    cfgFixityOverrides :: FixityMap,
    -- | Known dependencies, if any
    cfgDependencies :: !(Set String),
    -- | Do formatting faster but without automatic detection of defects
    cfgUnsafe :: !Bool,
    -- | Output information useful for debugging
    cfgDebug :: !Bool,
    -- | Checks if re-formatting the result is idempotent
    cfgCheckIdempotence :: !Bool,
    -- | How to parse the input (regular haskell module or Backpack file)
    cfgSourceType :: !SourceType,
    -- | Whether to use colors and other features of ANSI terminals
    cfgColorMode :: !ColorMode,
    -- | Region selection
    cfgRegion :: !region,
    cfgPrinterOpts :: !PrinterOptsTotal
  }
  deriving (Eq, Show, Functor, Generic)

-- | Region selection as the combination of start and end line numbers.
data RegionIndices = RegionIndices
  { -- | Start line of the region to format
    regionStartLine :: !(Maybe Int),
    -- | End line of the region to format
    regionEndLine :: !(Maybe Int)
  }
  deriving (Eq, Show)

-- | Region selection as the length of the literal prefix and the literal
-- suffix.
data RegionDeltas = RegionDeltas
  { -- | Prefix length in number of lines
    regionPrefixLength :: !Int,
    -- | Suffix length in number of lines
    regionSuffixLength :: !Int
  }
  deriving (Eq, Show)

-- | Default @'Config' 'RegionIndices'@.
defaultConfig :: Config RegionIndices
defaultConfig =
  Config
    { cfgDynOptions = [],
      cfgFixityOverrides = Map.empty,
      cfgDependencies = Set.empty,
      cfgUnsafe = False,
      cfgDebug = False,
      cfgCheckIdempotence = False,
      cfgSourceType = ModuleSource,
      cfgColorMode = Auto,
      cfgRegion =
        RegionIndices
          { regionStartLine = Nothing,
            regionEndLine = Nothing
          },
      cfgPrinterOpts = defaultPrinterOpts
    }

-- | Convert 'RegionIndices' into 'RegionDeltas'.
regionIndicesToDeltas ::
  -- | Total number of lines in the input
  Int ->
  -- | Region indices
  RegionIndices ->
  -- | Region deltas
  RegionDeltas
regionIndicesToDeltas total RegionIndices {..} =
  RegionDeltas
    { regionPrefixLength = maybe 0 (subtract 1) regionStartLine,
      regionSuffixLength = maybe 0 (total -) regionEndLine
    }

-- | A wrapper for dynamic options.
newtype DynOption = DynOption
  { unDynOption :: String
  }
  deriving (Eq, Ord, Show)

-- | Convert 'DynOption' to @'GHC.Located' 'String'@.
dynOptionToLocatedStr :: DynOption -> GHC.Located String
dynOptionToLocatedStr (DynOption o) = GHC.L GHC.noSrcSpan o

----------------------------------------------------------------------------
-- Fourmolu configuration

-- | Options controlling formatting output.
data PrinterOpts f = PrinterOpts
  { -- | Number of spaces to use for indentation
    poIndentation :: f Int,
    -- | Whether to place commas at start or end of lines
    poCommaStyle :: f CommaStyle,
    -- | Whether to place commas at start or end of import-export lines
    poImportExportCommaStyle :: f CommaStyle,
    -- | Whether to indent `where` blocks
    poIndentWheres :: f Bool,
    -- | Leave space before opening record brace
    poRecordBraceSpace :: f Bool,
    -- | Trailing commas with parentheses on separate lines
    poDiffFriendlyImportExport :: f Bool,
    -- | Be less opinionated about spaces/newlines etc.
    poRespectful :: f Bool,
    -- | How to print doc comments
    poHaddockStyle :: f HaddockPrintStyle,
    -- | Number of newlines between top-level decls
    poNewlinesBetweenDecls :: f Int
  }
  deriving (Generic)

data CommaStyle
  = Leading
  | Trailing
  deriving (Eq, Ord, Show, Generic, Bounded, Enum)

data HaddockPrintStyle
  = HaddockSingleLine
  | HaddockMultiLine
  deriving (Eq, Ord, Show, Generic, Bounded, Enum)

-- | A version of 'PrinterOpts' where any field can be empty.
-- This corresponds to the information in a config file or in CLI options.
type PrinterOptsPartial = PrinterOpts Maybe

deriving instance Eq PrinterOptsPartial
deriving instance Show PrinterOptsPartial

instance Semigroup PrinterOptsPartial where
  (<>) = fillMissingPrinterOpts

instance Monoid PrinterOptsPartial where
  mempty = PrinterOpts Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

instance Aeson.FromJSON PrinterOptsPartial where
  parseJSON =
    Aeson.genericParseJSON
      Aeson.defaultOptions
        { Aeson.fieldLabelModifier = Aeson.camelTo2 '-' . dropWhile isLower
        }

-- | A version of 'PrinterOpts' without empty fields.
type PrinterOptsTotal = PrinterOpts Identity

deriving instance Eq PrinterOptsTotal
deriving instance Show PrinterOptsTotal

overFields :: (forall a. f a -> g a) -> PrinterOpts f -> PrinterOpts g
overFields f PrinterOpts {..} =
  PrinterOpts
    { poIndentation = f poIndentation,
      poCommaStyle = f poCommaStyle,
      poImportExportCommaStyle = f poImportExportCommaStyle,
      poIndentWheres = f poIndentWheres,
      poRecordBraceSpace = f poRecordBraceSpace,
      poDiffFriendlyImportExport = f poDiffFriendlyImportExport,
      poRespectful = f poRespectful,
      poHaddockStyle = f poHaddockStyle,
      poNewlinesBetweenDecls = f poNewlinesBetweenDecls
    }

defaultPrinterOpts :: PrinterOptsTotal
defaultPrinterOpts = overFields (Identity . metaDefault) printerOptsMeta

-- | Fill the field values that are 'Nothing' in the first argument
-- with the values of the corresponding fields of the second argument.
fillMissingPrinterOpts ::
  forall f.
  Applicative f =>
  PrinterOptsPartial ->
  PrinterOpts f ->
  PrinterOpts f
fillMissingPrinterOpts p1 p2 = overFields fillField printerOptsMeta
  where
    fillField :: PrinterOptsFieldMeta a -> f a
    fillField meta = maybe (metaGetField meta p2) pure (metaGetField meta p1)

-- | Source of truth for how PrinterOpts is parsed from configuration sources.
data PrinterOptsFieldMeta a where
  PrinterOptsFieldMeta ::
    { -- In future versions of GHC, this could be replaced with a
      -- `metaProxyField = Proxy @"poIndentation"` field using `HasField`
      -- https://gitlab.haskell.org/ghc/ghc/-/issues/20989
      metaGetField :: forall f. PrinterOpts f -> f a,
      metaDefault :: a
    } ->
    PrinterOptsFieldMeta a

printerOptsMeta :: PrinterOpts PrinterOptsFieldMeta
printerOptsMeta =
  PrinterOpts
    { poIndentation =
        PrinterOptsFieldMeta
          { metaGetField = poIndentation,
            metaDefault = 4
          },
      poCommaStyle =
        PrinterOptsFieldMeta
          { metaGetField = poCommaStyle,
            metaDefault = Leading
          },
      poImportExportCommaStyle =
        PrinterOptsFieldMeta
          { metaGetField = poImportExportCommaStyle,
            metaDefault = Trailing
          },
      poIndentWheres =
        PrinterOptsFieldMeta
          { metaGetField = poIndentWheres,
            metaDefault = False
          },
      poRecordBraceSpace =
        PrinterOptsFieldMeta
          { metaGetField = poRecordBraceSpace,
            metaDefault = False
          },
      poDiffFriendlyImportExport =
        PrinterOptsFieldMeta
          { metaGetField = poDiffFriendlyImportExport,
            metaDefault = True
          },
      poRespectful =
        PrinterOptsFieldMeta
          { metaGetField = poRespectful,
            metaDefault = True
          },
      poHaddockStyle =
        PrinterOptsFieldMeta
          { metaGetField = poHaddockStyle,
            metaDefault = HaddockMultiLine
          },
      poNewlinesBetweenDecls =
        PrinterOptsFieldMeta
          { metaGetField = poNewlinesBetweenDecls,
            metaDefault = 1
          }
    }

instance Aeson.FromJSON CommaStyle where
  parseJSON =
    Aeson.genericParseJSON
      Aeson.defaultOptions
        { Aeson.constructorTagModifier = Aeson.camelTo2 '-'
        }

instance Aeson.FromJSON HaddockPrintStyle where
  parseJSON =
    Aeson.genericParseJSON
      Aeson.defaultOptions
        { Aeson.constructorTagModifier = drop (length ("haddock-" :: String)) . Aeson.camelTo2 '-'
        }

----------------------------------------------------------------------------
-- Loading Fourmolu configuration

data FourmoluConfig = FourmoluConfig
  { cfgFilePrinterOpts :: PrinterOptsPartial,
    cfgFileFixities :: FixityMap
  }
  deriving (Eq, Show)

instance Aeson.FromJSON FourmoluConfig where
  parseJSON = Aeson.withObject "FourmoluConfig" $ \o -> do
    cfgFilePrinterOpts <- Aeson.parseJSON (Aeson.Object o)
    rawFixities <- o .:? "fixities" .!= []
    cfgFileFixities <-
      case mapM parseFixityDeclaration rawFixities of
        Right fixities -> return . Map.fromList . concat $ fixities
        Left e -> fail $ errorBundlePretty e
    return FourmoluConfig {..}

-- | Read options from a config file, if found.
-- Looks recursively in parent folders, then in 'XdgConfig',
-- for a file named /fourmolu.yaml/.
loadConfigFile :: FilePath -> IO ConfigFileLoadResult
loadConfigFile path = do
  root <- makeAbsolute path
  xdg <- getXdgDirectory XdgConfig ""
  let dirs = reverse $ xdg : scanl1 (</>) (splitPath root)
  findFile dirs configFileName >>= \case
    Nothing -> return $ ConfigNotFound dirs
    Just file ->
      either (ConfigParseError file) (ConfigLoaded file)
        <$> Yaml.decodeFileEither file

-- | The result of calling 'loadConfigFile'.
data ConfigFileLoadResult
  = ConfigLoaded FilePath FourmoluConfig
  | ConfigParseError FilePath Yaml.ParseException
  | ConfigNotFound [FilePath]

-- | Expected file name for YAML config.
configFileName :: FilePath
configFileName = "fourmolu.yaml"
