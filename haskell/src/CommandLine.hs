{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms   #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE ViewPatterns      #-}
module CommandLine
( commandLine
, identifyFile'
, FileType(..)
, copyDirRecursive
, runDolphin
, blackVenue
) where

import qualified Amplitude.PS2.Ark                as AmpArk
import           Audio                            (Audio (Input), applyPansVols,
                                                   audioLength, audioMD5,
                                                   fadeEnd, fadeStart, runAudio)
import           Build                            (loadYaml, shakeBuildFiles)
import           Codec.Picture                    (writePng)
import           Codec.Picture.Types              (dropTransparency, pixelMap)
import           Config
import           Control.Monad.Codec.Onyx.JSON    (toJSON, yamlEncodeFile)
import           Control.Monad.Extra              (filterM, forM, forM_, guard,
                                                   when)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Resource     (MonadResource, ResourceT,
                                                   runResourceT)
import           Control.Monad.Trans.StackTrace
import           Data.Binary.Codec.Class
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as B8
import qualified Data.ByteString.Lazy             as BL
import           Data.ByteString.Lazy.Char8       ()
import           Data.Char                        (isAlphaNum, isAscii, isDigit,
                                                   isUpper, toLower)
import qualified Data.Conduit.Audio               as CA
import           Data.Conduit.Audio.Sndfile       (sinkSnd, sourceSndFrom)
import           Data.Default.Class               (def)
import qualified Data.Digest.Pure.MD5             as MD5
import           Data.DTA.Lex                     (scanStack)
import           Data.DTA.Parse                   (parseStack)
import qualified Data.DTA.Serialize               as D
import qualified Data.DTA.Serialize.Magma         as RBProj
import qualified Data.DTA.Serialize.RB3           as D
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Foldable                    (toList)
import qualified Data.HashMap.Strict              as HM
import           Data.List.Extra                  (find, stripSuffix, unsnoc)
import           Data.List.NonEmpty               (NonEmpty ((:|)))
import qualified Data.Map                         as Map
import           Data.Maybe                       (catMaybes, fromMaybe,
                                                   listToMaybe, mapMaybe)
import           Data.SimpleHandle                (Folder (..),
                                                   byteStringSimpleHandle,
                                                   findFileCI,
                                                   handleToByteString,
                                                   makeHandle, saveHandleFolder,
                                                   useHandle)
import qualified Data.Text                        as T
import qualified Data.Text.Encoding               as TE
import qualified Data.Yaml                        as Y
import qualified GuitarHeroII.Ark                 as GHArk
import           GuitarHeroII.Audio               (readVGS)
import           GuitarHeroII.File                (GH2File (..))
import           GuitarHeroII.PartGuitar          (nullPart)
import           GuitarHeroIOS                    (extractIGA)
import qualified Image
import           Magma                            (getRBAFile, runMagma,
                                                   runMagmaMIDI, runMagmaV1)
import           MoggDecrypt                      (moggToOgg, oggToMogg)
import           Neversoft.Audio                  (aesDecrypt, aesEncrypt,
                                                   fsbDecrypt)
import           Neversoft.Checksum               (knownKeys, qbKeyCRC)
import           Neversoft.Export                 (makeMetadataLIVE,
                                                   shareMetadata)
import           Neversoft.Note                   (loadNoteFile)
import           Neversoft.Pak                    (Node (..), buildPak,
                                                   nodeFileType, qsBank,
                                                   splitPakNodes)
import           Neversoft.QB                     (discardStrings, lookupQB,
                                                   lookupQS, parseQB, putQB)
import           OpenProject
import           OSFiles                          (copyDirRecursive)
import           PrettyDTA                        (DTASingle (..),
                                                   readDTASingles,
                                                   readFileSongsDTA, readRB3DTA,
                                                   writeDTASingle)
import           ProKeysRanges                    (closeShiftsFile)
import           Reaper.Build                     (TuningInfo (..), makeReaper)
import           RockBand.Codec                   (mapTrack)
import qualified RockBand.Codec.File              as RBFile
import           RockBand.Codec.Vocal             (nullVox)
import           RockBand.Common                  (Difficulty (..),
                                                   pattern RNil, pattern Wait,
                                                   makeEdgeCPV)
import qualified RockBand.IOS                     as IOS
import           RockBand.Milo                    (SongPref, autoLipsync,
                                                   beatlesLipsync,
                                                   defaultTransition,
                                                   englishSyllables,
                                                   lipsyncFromMIDITrack,
                                                   loadVisemesRB3,
                                                   loadVisemesTBRB, packMilo,
                                                   putLipsync, setBeatles,
                                                   testConvertLipsync,
                                                   unpackMilo)
import           RockBand.Score
import           Rocksmith.PSARC                  (extractPSARC)
import qualified Sound.File.Sndfile               as Snd
import qualified Sound.MIDI.File                  as F
import qualified Sound.MIDI.File.Event            as E
import qualified Sound.MIDI.File.Event.Meta       as Meta
import           Sound.MIDI.File.FastParse        (getMIDI)
import qualified Sound.MIDI.File.Save             as Save
import qualified Sound.MIDI.Script.Base           as MS
import qualified Sound.MIDI.Script.Parse          as MS
import qualified Sound.MIDI.Script.Read           as MS
import qualified Sound.MIDI.Script.Scan           as MS
import qualified Sound.MIDI.Util                  as U
import           STFS.Package
import           System.Console.GetOpt
import qualified System.Directory                 as Dir
import           System.FilePath                  (dropExtension,
                                                   dropTrailingPathSeparator,
                                                   takeDirectory, takeExtension,
                                                   takeFileName, (-<.>), (<.>),
                                                   (</>))
import qualified System.IO                        as IO
import           Text.Decode                      (decodeGeneral)
import           Text.Printf                      (printf)
import           Text.Read                        (readMaybe)
import           U8                               (packU8)

#ifdef WINDOWS
import           Data.Bits                        (testBit)
import           System.Win32.File                (getLogicalDrives)
#else
import           Data.List                        (isPrefixOf)
import           System.MountPoints
#endif

loadRBProj :: (SendMessage m, MonadIO m) => FilePath -> StackTraceT m RBProj.RBProj
loadRBProj f = inside f $ do
  stackIO (decodeGeneral <$> B.readFile f)
    >>= scanStack >>= parseStack >>= D.unserialize D.stackChunks

getInfoForSTFS :: (SendMessage m, MonadIO m) => FilePath -> FilePath -> StackTraceT m (T.Text, T.Text)
getInfoForSTFS dir stfs = do
  let dta = dir </> "songs/songs.dta"
  ex <- stackIO $ Dir.doesFileExist dta
  fromMaybe (T.pack $ takeFileName stfs, T.pack stfs) <$> if ex
    then errorToWarning $ do
      (_, pkg, _) <- readRB3DTA dta
      return (D.name pkg, D.name pkg <> maybe "" (\artist -> " (" <> artist <> ")") (D.artist pkg))
    else return Nothing

installSTFS :: (MonadIO m) => FilePath -> FilePath -> StackTraceT m ()
installSTFS stfs usb = do
  (titleID, sign) <- stfsFolder stfs
  packageTitle <- stackIO $ IO.withBinaryFile stfs IO.ReadMode $ \h -> do
    IO.hSeek h IO.AbsoluteSeek 0x411
    bs <- B.hGet h 0x80
    return $ T.takeWhile (/= '\0') $ TE.decodeUtf16BE bs
  stfsHash <- stackIO $ show . MD5.md5 <$> BL.readFile stfs
  let folder = "Content/0000000000000000" </> w32 titleID </> w32 sign
      w32 :: Word32 -> FilePath
      w32 = printf "%08x"
      file = take 32 $ "o" ++ take 7 stfsHash ++ T.unpack
        (T.filter (\c -> isAscii c && isAlphaNum c) packageTitle)
  stackIO $ Dir.createDirectoryIfMissing True $ usb </> folder
  stackIO $ Dir.copyFile stfs $ usb </> folder </> file

findXbox360USB :: (MonadIO m) => StackTraceT m [FilePath]
findXbox360USB = stackIO $ do
#ifdef WINDOWS
  dword <- getLogicalDrives
  let drives = [ letter : ":\\" | (letter, i) <- zip ['A'..'Z'] [0..], dword `testBit` i ]
#else
  mnts <- getMounts
  let drives = map mnt_dir $ flip filter mnts $ \mnt ->
        ("/dev/" `isPrefixOf` mnt_fsname mnt) && (mnt_dir mnt /= "/")
#endif
  filterM (\drive -> Dir.doesDirectoryExist $ drive </> "Content") drives

data Command = Command
  { commandWord  :: T.Text
  , commandRun   :: forall m. (MonadResource m) => [FilePath] -> [OnyxOption] -> StackTraceT (QueueLog m) [FilePath]
  , commandDesc  :: T.Text
  , commandUsage :: T.Text
  }

identifyFile :: FilePath -> IO FileResult
identifyFile fp = Dir.doesFileExist fp >>= \case
  True -> case map toLower $ takeExtension fp of
    ".yml" -> return $ FileType FileSongYaml fp
    ".rbproj" -> return $ FileType FileRBProj fp
    ".moggsong" -> return $ FileType FileMOGGSong fp
    ".midtxt" -> return $ FileType FileMidiText fp
    ".mogg" -> return $ FileType FileMOGG fp
    ".zip" -> return $ FileType FileZip fp
    ".chart" -> return $ FileType FileChart fp
    ".psarc" -> return $ FileType FilePSARC fp
    _ -> case takeFileName fp of
      "song.ini" -> return $ FileType FilePS fp
      _ -> do
        magic <- IO.withBinaryFile fp IO.ReadMode $ \h -> BL.hGet h 4
        return $ case magic of
          "RBSF" -> FileType FileRBA fp
          "CON " -> FileType FileSTFS fp
          "LIVE" -> FileType FileSTFS fp
          "MThd" -> FileType FileMidi fp
          "fLaC" -> FileType FileFLAC fp
          "OggS" -> FileType FileOGG fp
          "RIFF" -> FileType FileWAV fp
          _      -> case BL.unpack magic of
            [0xAF, 0xDE, 0xBE, 0xCA] -> FileType FileMilo fp
            [0xAF, 0xDE, 0xBE, 0xCB] -> FileType FileMilo fp
            [0xAF, 0xDE, 0xBE, 0xCC] -> FileType FileMilo fp
            [0xAF, 0xDE, 0xBE, 0xCD] -> FileType FileMilo fp
            _                        -> FileUnrecognized
  False -> Dir.doesDirectoryExist fp >>= \case
    True -> Dir.doesFileExist (fp </> "song.yml") >>= \case
      True -> return $ FileType FileSongYaml $ fp </> "song.yml"
      False -> Dir.doesFileExist (fp </> "song.ini") >>= \case
        True -> return $ FileType FilePS $ fp </> "song.ini"
        False -> Dir.doesFileExist (fp </> "notes.chart") >>= \case
          True -> return $ FileType FileChart $ fp </> "notes.chart"
          False -> do
            ents <- Dir.listDirectory fp
            case filter (\ent -> takeExtension ent == ".rbproj") ents of
              [ent] -> return $ FileType FileRBProj $ fp </> ent
              _     -> Dir.doesFileExist (fp </> "songs/songs.dta") >>= \case
                True -> return $ FileType FileDTA $ fp </> "songs/songs.dta"
                False -> return FileUnrecognized
    False -> return FileDoesNotExist

data FileResult
  = FileType FileType FilePath
  | FileDoesNotExist
  | FileUnrecognized
  deriving (Eq, Ord, Show)

data FileType
  = FileSongYaml
  | FileSTFS
  | FileDTA
  | FileRBA
  | FilePS
  | FileChart
  | FileMidi
  | FileMidiText
  | FileRBProj
  | FileMOGGSong
  | FileOGG
  | FileMOGG
  | FileFLAC
  | FileWAV
  | FileZip
  | FilePSARC
  | FileMilo
  deriving (Eq, Ord, Show)

identifyFile' :: (MonadIO m) => FilePath -> StackTraceT m (FileType, FilePath)
identifyFile' file = stackIO (identifyFile file) >>= \case
  FileDoesNotExist     -> fatal $ "Path does not exist: " <> file
  FileUnrecognized     -> fatal $ "File/directory type not recognized: " <> file
  FileType ftype fpath -> return (ftype, fpath)

optionalFile :: (MonadIO m) => [FilePath] -> StackTraceT m (FileType, FilePath)
optionalFile files = case files of
  []     -> identifyFile' "."
  [file] -> identifyFile' file
  _      -> fatal $ "Command expected 0 or 1 arguments, given " <> show (length files)

unrecognized :: (Monad m) => FileType -> FilePath -> StackTraceT m a
unrecognized ftype fpath = fatal $ "Unsupported file for command (" <> show ftype <> "): " <> fpath

outputFile :: (Monad m) => [OnyxOption] -> m FilePath -> m FilePath
outputFile opts dft = case [ to | OptTo to <- opts ] of
  []     -> dft
  to : _ -> return to

optIndex :: [OnyxOption] -> Maybe Int
optIndex opts = listToMaybe [ i | OptIndex i <- opts ]

buildTarget :: (MonadResource m) => FilePath -> [OnyxOption] -> StackTraceT (QueueLog m) (Target FilePath, FilePath)
buildTarget yamlPath opts = do
  songYaml <- loadYaml yamlPath
  targetName <- case [ t | OptTarget t <- opts ] of
    []    -> fatal "command requires --target, none given"
    t : _ -> return t
  audioDirs <- withProject (optIndex opts) yamlPath getAudioDirs
  target <- case HM.lookup targetName $ _targets songYaml of
    Nothing     -> fatal $ "Target not found in YAML file: " <> show targetName
    Just target -> return target
  let built = case target of
        RB3   {} -> "gen/target" </> T.unpack targetName </> "rb3con"
        RB2   {} -> "gen/target" </> T.unpack targetName </> "rb2con"
        PS    {} -> "gen/target" </> T.unpack targetName </> "ps.zip"
        GH2   {} -> "gen/target" </> T.unpack targetName </> "gh2.zip"
        GH5   {} -> undefined -- TODO
        RS    {} -> undefined -- TODO
        Melody{} -> undefined -- TODO
        Konga {} -> undefined -- TODO
  shakeBuildFiles audioDirs yamlPath [built]
  return (target, takeDirectory yamlPath </> built)

getMaybePlan :: [OnyxOption] -> Maybe T.Text
getMaybePlan opts = listToMaybe [ p | OptPlan p <- opts ]

getPlanName :: (SendMessage m, MonadIO m) => Maybe T.Text -> FilePath -> [OnyxOption] -> StackTraceT m T.Text
getPlanName defaultPlan yamlPath opts = case getMaybePlan opts of
  Just p  -> return p
  Nothing -> do
    songYaml <- loadYaml yamlPath
    case HM.keys $ _plans (songYaml :: SongYaml FilePath) of
      [p]   -> return p
      plans -> let
        err = fatal $ "No --plan given, and YAML file doesn't have exactly 1 plan: " <> show plans
        in case defaultPlan of
          Nothing -> err
          Just p  -> if elem p plans then return p else err

getInputMIDI :: (SendMessage m, MonadIO m) => [FilePath] -> StackTraceT m FilePath
getInputMIDI files = optionalFile files >>= \case
  (FileSongYaml, yamlPath) -> return $ takeDirectory yamlPath </> "notes.mid"
  (FileRBProj, rbprojPath) -> do
    rbproj <- loadRBProj rbprojPath
    return $ T.unpack $ RBProj.midiFile $ RBProj.midi $ RBProj.project rbproj
  (FileMidi, mid) -> return mid
  (FilePS, ini) -> return $ takeDirectory ini </> "notes.mid"
  (ftype, fpath) -> unrecognized ftype fpath

undone :: (Monad m) => StackTraceT m a
undone = fatal "Feature not built yet..."

changeToVenueGen :: (SendMessage m, MonadIO m) => FilePath -> StackTraceT m ()
changeToVenueGen dir = do
  let midPath = dir </> "notes.mid"
  mid <- RBFile.loadMIDI midPath
  stackIO $ Save.toFile midPath $ RBFile.showMIDIFile' $ RBFile.convertToVenueGen mid

commands :: [Command]
commands =

  [ Command
    { commandWord = "build"
    , commandDesc = "Compile an onyx or Magma project."
    , commandUsage = T.unlines
      [ "onyx build --target rb3 --to new_rb3con"
      , "onyx build --target ps --to new_ps.zip"
      , "onyx build mycoolsong.yml --target rb3 --to new_rb3con"
      , "onyx build song.rbproj"
      , "onyx build song.rbproj --to new.rba"
      -- , "onyx build song.rbproj --to new_rb3con"
      ]
    , commandRun = \files opts -> optionalFile files >>= \case
      (FileSongYaml, yamlPath) -> do
        out <- outputFile opts $ fatal "onyx build (yaml) requires --to, none given"
        (_, built) <- buildTarget yamlPath opts
        stackIO $ Dir.copyFile built out
        return [out]
      (FileRBProj, rbprojPath) -> do
        rbproj <- loadRBProj rbprojPath
        out <- fmap (takeDirectory rbprojPath </>)
          $ outputFile opts $ return $ T.unpack $ RBProj.destinationFile $ RBProj.project rbproj
        let isMagmaV2 = case RBProj.projectVersion $ RBProj.project rbproj of
              24 -> True
              5  -> False -- v1
              _  -> True -- need to do more testing
        if isMagmaV2
          then runMagma   rbprojPath out >>= lg
          else runMagmaV1 rbprojPath out >>= lg
        -- TODO: handle CON conversion
        return [out]
      (ftype, fpath) -> unrecognized ftype fpath
    }

  , Command
    { commandWord = "shake"
    , commandDesc = "For debug use only."
    , commandUsage = "onyx file mysong.yml file1 [file2...]"
    , commandRun = \files opts -> case files of
      [] -> return []
      yml : builds -> identifyFile' yml >>= \case
        (FileSongYaml, yml') -> do
          audioDirs <- withProject (optIndex opts) yml getAudioDirs
          shakeBuildFiles audioDirs yml' builds
          return $ map (takeDirectory yml' </>) builds
        (ftype, fpath) -> unrecognized ftype fpath
    }

  , Command
    { commandWord = "install"
    , commandDesc = "Install a song to a USB drive or game folder."
    , commandUsage = ""
    , commandRun = \files opts -> let
      doInstall ftype fpath = case ftype of
        FileSongYaml -> do
          (target, built) <- buildTarget fpath opts
          let ftype' = case target of
                PS    {} -> FileZip
                RB3   {} -> FileSTFS
                RB2   {} -> FileSTFS
                GH2   {} -> undefined -- TODO
                GH5   {} -> undefined -- TODO
                RS    {} -> undefined -- TODO
                Melody{} -> undefined -- TODO
                Konga {} -> undefined -- TODO
          doInstall ftype' built
        FileRBProj -> undone -- install con to usb drive
        FileSTFS -> do
          drive <- outputFile opts $ findXbox360USB >>= \case
            [d] -> return d
            [ ] -> fatal "onyx install (stfs): no Xbox 360 USB drives found"
            _   -> fatal "onyx install (stfs): more than 1 Xbox 360 USB drive found"
          installSTFS fpath drive
        FileRBA -> undone -- convert to con, install to usb drive
        FilePS -> undone -- install to PS music dir
        FileZip -> undone -- install to PS music dir
        _ -> unrecognized ftype fpath
      in optionalFile files >>= uncurry doInstall >> return []
    }

  , Command
    { commandWord = "reap"
    , commandDesc = "Open a MIDI file (with audio) in REAPER."
    , commandUsage = ""
    , commandRun = \files opts -> do
      fpath <- case files of
        []  -> return "."
        [x] -> return x
        _   -> fatal "Expected 0 or 1 files/folders"
      if takeExtension fpath == ".mid"
        then do
          rpp <- outputFile opts $ return $ fpath -<.> "RPP"
          makeReaper (TuningInfo [] 0) fpath fpath [] rpp
          return [rpp]
        else do
          proj <- openProject (optIndex opts) fpath
          yamlDir <- case projectRelease proj of
            Nothing -> return $ takeDirectory $ projectLocation proj
            Just _  -> do
              out <- outputFile opts $ return $ projectTemplate proj ++ "_reaper"
              stackIO $ Dir.createDirectoryIfMissing False out
              copyDirRecursive (takeDirectory $ projectLocation proj) out
              return out
          let yamlPath = yamlDir </> "song.yml"
          planName <- getPlanName (Just "author") yamlPath opts
          let rpp = "notes-" <> T.unpack planName <> ".RPP"
          when (OptVenueGen `elem` opts) $ changeToVenueGen yamlDir
          audioDirs <- withProject Nothing yamlPath getAudioDirs
          shakeBuildFiles audioDirs yamlPath [rpp]
          let rppFull = yamlDir </> "notes.RPP"
          stackIO $ Dir.renameFile (yamlDir </> rpp) rppFull
          return [rppFull]
    }

  , Command
    { commandWord = "player"
    , commandDesc = "Create a web browser chart playback app."
    , commandUsage = ""
    , commandRun = \files opts -> do
      fpath <- case files of
        []  -> return "."
        [x] -> return x
        _   -> fatal "Expected 0 or 1 files/folders"
      proj <- openProject (optIndex opts) fpath
      out <- outputFile opts $ return $ projectTemplate proj ++ "_player"
      player <- buildPlayer (getMaybePlan opts) proj
      case projectRelease proj of
        Nothing -> return [player </> "index.html"] -- onyx project, return folder directly
        Just _ -> do
          stackIO $ Dir.createDirectoryIfMissing False out
          copyDirRecursive player out
          return [out </> "index.html"]
    }

  , Command
    { commandWord = "check"
    , commandDesc = "Check for any authoring errors in a project."
    , commandUsage = ""
    , commandRun = \files opts -> optionalFile files >>= \case
      (FileSongYaml, yamlPath) -> do
        targetName <- case [ t | OptTarget t <- opts ] of
          []    -> fatal "command requires --target, none given"
          t : _ -> return t
        -- TODO: handle non-RB3 targets
        let built = "gen/target" </> T.unpack targetName </> "notes-magma-export.mid"
        audioDirs <- withProject (optIndex opts) yamlPath getAudioDirs
        shakeBuildFiles audioDirs yamlPath [built]
        return []
      (FileRBProj, rbprojPath) -> do
        rbproj <- loadRBProj rbprojPath
        let isMagmaV2 = case RBProj.projectVersion $ RBProj.project rbproj of
              24 -> True
              5  -> False -- v1
              _  -> True -- need to do more testing
        tempDir "onyx_check" $ \tmp -> if isMagmaV2
          then runMagmaMIDI rbprojPath (tmp </> "out.mid") >>= lg
          else undone
        return []
      (ftype, fpath) -> unrecognized ftype fpath
    }

  , Command
    { commandWord = "import"
    , commandDesc = "Import a file into onyx's project format."
    , commandUsage = ""
    , commandRun = \files opts -> do
      fpath <- case files of
        []  -> return "."
        [x] -> return x
        _   -> fatal "Expected 0 or 1 files/folders"
      proj <- openProject (optIndex opts) fpath
      out <- outputFile opts $ return $ projectTemplate proj ++ "_import"
      stackIO $ Dir.createDirectoryIfMissing False out
      copyDirRecursive (takeDirectory $ projectLocation proj) out
      when (OptVenueGen `elem` opts) $ changeToVenueGen out
      return [out]
    }

  , Command
    { commandWord = "hanging"
    , commandDesc = "Find pro keys range shifts with hanging notes."
    , commandUsage = T.unlines
      [ "onyx hanging mysong.yml"
      , "onyx hanging notes.mid"
      ]
    , commandRun = \files opts -> optionalFile files >>= \(ftype, fpath) -> do
      let withMIDI mid = RBFile.loadMIDI mid >>= lg . T.unpack . closeShiftsFile
      case ftype of
        FileSongYaml -> withProject (optIndex opts) fpath $ proKeysHanging $ getMaybePlan opts
        FileRBProj   -> do
          rbproj <- loadRBProj fpath
          let midPath = T.unpack $ RBProj.midiFile $ RBProj.midi $ RBProj.project rbproj
          withMIDI (takeDirectory fpath </> midPath)
        FileSTFS     -> undone
        FileRBA      -> tempDir "onyx_hanging_rba" $ \tmp -> do
          let midPath = tmp </> "notes.mid"
          getRBAFile 1 fpath midPath
          withMIDI midPath
        FilePS       -> withMIDI $ takeDirectory fpath </> "notes.mid"
        FileMidi     -> withMIDI fpath
        _            -> unrecognized ftype fpath
      return []
    }

  , Command
    { commandWord = "stfs"
    , commandDesc = "Compile a folder's contents into an Xbox 360 STFS file."
    , commandUsage = T.unlines
      [ "onyx stfs my_folder"
      , "onyx stfs my_folder --to new_rb3con"
      , "onyx stfs my_folder --to new_rb3con --game rb3"
      , "onyx stfs my_folder --to new_rb3con --game rb2"
      ]
    , commandRun = \files opts -> case files of
      [dir] -> stackIO (Dir.doesDirectoryExist dir) >>= \case
        True -> do
          let game = fromMaybe GameRB3 $ listToMaybe [ g | OptGame g <- opts ]
          (pkg, suffix) <- case game of
            GameRB3 -> return (rb3pkg, "_rb3con")
            GameRB2 -> return (rb2pkg, "_rb2con")
            GameGH2 -> return (gh2pkg, "_gh2live")
            _       -> fatal "Unsupported as game for stfs command"
          stfs <- outputFile opts
            $ (<> suffix) . dropTrailingPathSeparator
            <$> stackIO (Dir.makeAbsolute dir)
          (title, desc) <- getInfoForSTFS dir stfs
          pkg title desc dir stfs
          return [stfs]
        False -> fatal $ "onyx stfs expected directory; given: " <> dir
      _ -> fatal $ "onyx stfs expected 1 argument, given " <> show (length files)
    }

  , Command
    { commandWord = "extract"
    , commandDesc = "Extract various archive formats to a folder."
    , commandUsage = T.unlines
      [ "onyx extract file_in"
      , "onyx extract file_in --to folder_out"
      ]
    , commandRun = \files opts -> forM files $ \f -> identifyFile' f >>= \case
      (FileSTFS, stfs) -> do
        out <- outputFile opts $ return $ stfs ++ "_extract"
        stackIO $ Dir.createDirectoryIfMissing False out
        stackIO $ extractSTFS stfs out
        repack <- stackIO $ withSTFSPackage stfs $ return . repackOptions
        stackIO $ saveHandleFolder (saveCreateOptions repack) $ out </> "onyx-repack"
        return out
      (FilePSARC, psarc) -> do
        out <- outputFile opts $ return $ psarc ++ "_extract"
        stackIO $ extractPSARC psarc out
        return out
      (FileRBA, rba) -> do
        out <- outputFile opts $ return $ rba ++ "_extract"
        stackIO $ Dir.createDirectoryIfMissing False out
        getRBAFile 0 rba $ out </> "songs.dta"
        getRBAFile 1 rba $ out </> "notes.mid"
        getRBAFile 2 rba $ out </> "audio.mogg"
        getRBAFile 3 rba $ out </> "song.milo"
        getRBAFile 4 rba $ out </> "cover.bmp"
        getRBAFile 5 rba $ out </> "weights.bin"
        getRBAFile 6 rba $ out </> "extra.dta"
        return out
      (FileMilo, milo) -> do
        out <- outputFile opts $ return $ milo ++ "_extract"
        unpackMilo milo out
        return out
      p -> fatal $ "Unexpected file type given to extractor: " <> show p
    }

  , Command
    { commandWord = "midi-text"
    , commandDesc = "Convert a MIDI file to/from a plaintext format."
    , commandUsage = ""
    , commandRun = \files opts -> optionalFile files >>= \(ftype, fpath) -> case ftype of
      FileMidi -> do
        out <- outputFile opts $ return $ fpath -<.> "midtxt"
        res <- MS.toStandardMIDI <$> RBFile.loadRawMIDI fpath
        case res of
          Left  err -> fatal err
          Right sm  -> stackIO $ writeFile out $ MS.showStandardMIDI (midiOptions opts) sm
        return [out]
      FileMidiText -> do
        out <- outputFile opts $ return $ fpath -<.> "mid"
        sf <- stackIO $ MS.readStandardFile . MS.parse . MS.scan <$> readFile fpath
        let (mid, warnings) = MS.fromStandardMIDI (midiOptions opts) sf
        mapM_ warn warnings
        stackIO $ Save.toFile out mid
        return [out]
      _ -> unrecognized ftype fpath
    }

  , Command
    { commandWord = "midi-text-git"
    , commandDesc = "Convert a MIDI file to a plaintext format. (for git use)"
    , commandUsage = "onyx midi-text-git in.mid > out.midtxt"
    , commandRun = \files opts -> case files of
      [mid] -> do
        res <- MS.toStandardMIDI <$> RBFile.loadRawMIDI mid
        case res of
          Left  err -> fatal err
          Right sm  -> lg $ MS.showStandardMIDI (midiOptions opts) sm
        return []
      _ -> fatal $ "onyx midi-text-git expected 1 argument, given " <> show (length files)
    }

  , Command
    { commandWord = "mogg"
    , commandDesc = "Add or remove a MOGG header to an OGG Vorbis file."
    , commandUsage = T.unlines
      [ "onyx mogg in.ogg --to out.mogg"
      , "onyx mogg in.mogg --to out.ogg"
      ]
    , commandRun = \files opts -> optionalFile files >>= \(ftype, fpath) -> case ftype of
      FileOGG -> do
        mogg <- outputFile opts $ return $ fpath -<.> "mogg"
        oggToMogg fpath mogg
        return [mogg]
      FileMOGG -> do
        ogg <- outputFile opts $ return $ fpath -<.> "ogg"
        moggToOgg fpath ogg
        return [ogg]
      _ -> unrecognized ftype fpath
    }

  , Command
    { commandWord = "merge"
    , commandDesc = "Take tracks from one MIDI file, and convert them to a different file's tempo map."
    , commandUsage = T.unlines
      [ "onyx merge base.mid tracks.mid pad  n --to out.mid"
      , "onyx merge base.mid tracks.mid drop n --to out.mid"
      ]
    , commandRun = \args opts -> case args of
      [base, tracks] -> do
        baseMid <- RBFile.loadMIDI base
        tracksMid <- RBFile.loadMIDI tracks
        out <- outputFile opts $ return $ tracks ++ ".merged.mid"
        let newMid = RBFile.mergeCharts (RBFile.TrackPad 0) baseMid tracksMid
        stackIO $ Save.toFile out $ RBFile.showMIDIFile' newMid
        return [out]
      [base, tracks, "pad", n] -> do
        baseMid <- RBFile.loadMIDI base
        tracksMid <- RBFile.loadMIDI tracks
        out <- outputFile opts $ return $ tracks ++ ".merged.mid"
        n' <- case readMaybe n of
          Nothing -> fatal "Invalid merge pad amount"
          Just d  -> return $ realToFrac (d :: Double)
        let newMid = RBFile.mergeCharts (RBFile.TrackPad n') baseMid tracksMid
        stackIO $ Save.toFile out $ RBFile.showMIDIFile' newMid
        return [out]
      [base, tracks, "drop", n] -> do
        baseMid <- RBFile.loadMIDI base
        tracksMid <- RBFile.loadMIDI tracks
        out <- outputFile opts $ return $ tracks ++ ".merged.mid"
        n' <- case readMaybe n of
          Nothing -> fatal "Invalid merge drop amount"
          Just d  -> return $ realToFrac (d :: Double)
        let newMid = RBFile.mergeCharts (RBFile.TrackDrop n') baseMid tracksMid
        stackIO $ Save.toFile out $ RBFile.showMIDIFile' newMid
        return [out]
      _ -> fatal "Invalid merge syntax"
    }

  , Command
    { commandWord = "add-track"
    , commandDesc = "Add an empty track to a MIDI file with a given name."
    , commandUsage = "onyx add-track \"TRACK NAME\" --to [notes.mid|song.yml]"
    , commandRun = \args opts -> do
      f <- outputFile opts $ return "."
      (ftype, fpath) <- identifyFile' f
      pathMid <- case ftype of
        FileMidi -> return fpath
        FileSongYaml -> return $ takeDirectory fpath </> "notes.mid"
        FileRBProj -> undone
        _ -> fatal "Unrecognized --to argument, expected .mid/.yml/.rbproj"
      mid <- RBFile.loadMIDI pathMid
      let existingTracks = RBFile.rawTracks $ RBFile.s_tracks mid
          existingNames = mapMaybe U.trackName existingTracks
      case filter (`notElem` existingNames) args of
        []      -> return ()
        newTrks -> stackIO $ Save.toFile pathMid $ RBFile.showMIDIFile' mid
          { RBFile.s_tracks = RBFile.RawFile $ existingTracks ++ map (`U.setTrackName` RTB.empty) newTrks
          }
      return [pathMid]
    }

  , Command
    { commandWord = "u8"
    , commandDesc = "Generate U8 packages for the Wii."
    , commandUsage = "onyx u8 dir --to out.app"
    , commandRun = \args opts -> case args of
      [dir] -> stackIO (Dir.doesDirectoryExist dir) >>= \case
        True -> do
          fout <- outputFile opts
            $ (<> ".app") . dropTrailingPathSeparator
            <$> stackIO (Dir.makeAbsolute dir)
          stackIO $ packU8 dir fout
          return [fout]
        False -> fatal $ "onyx u8 expected directory; given: " <> dir
      _ -> fatal "Expected 1 argument (folder to pack)"
    }

  , Command
    { commandWord = "dolphin-midi"
    , commandDesc = "Apply useful changes to MIDI files for Dolphin preview recording."
    , commandUsage = T.unlines
      [ "onyx dolphin-midi [notes.mid|song.yml|magma.rbproj|song.ini] [--wii-no-fills] [--wii-mustang-22]"
      , "# or run on current directory"
      , "onyx dolphin-midi [--wii-no-fills] [--wii-mustang-22]"
      , "# by default, creates .dolphin.mid. or specify --to"
      , "onyx dolphin-midi notes.mid --to new.mid [--wii-no-fills] [--wii-mustang-22]"
      ]
    , commandRun = \files opts -> do
      fin <- getInputMIDI files
      fout <- outputFile opts $ return $ fin -<.> "dolphin.mid"
      applyMidiFunction (getDolphinFunction opts) fin fout
      return [fout]
    }

  , Command
    { commandWord = "dolphin"
    , commandDesc = "Combine CON files into two U8 packages intended for RB3 in Dolphin."
    , commandUsage = "onyx dolphin 1_rb3con 2_rb3con --to dir/"
    , commandRun = \args opts -> do
      out <- outputFile opts $ fatal "need output folder for .app files"
      runDolphin args (getDolphinFunction opts) False out
    }

  , Command
    { commandWord = "vgs"
    , commandDesc = "Convert VGS audio to a set of WAV files."
    , commandUsage = "onyx vgs in.vgs"
    , commandRun = \args _opts -> case args of
      [fin] -> do
        srcs <- liftIO $ readVGS fin
        forM (zip [0..] srcs) $ \(i, src) -> do
          let fout = dropExtension fin ++ "_" ++ show (i :: Int) ++ ".wav"
          runAudio (CA.mapSamples CA.fractionalSample src) fout
          return fout
      _ -> fatal "Expected 1 argument (.vgs file)"
    }

  , Command
    { commandWord = "install-ark"
    , commandDesc = "Install a song into GH2 (PS2)."
    , commandUsage = "onyx install-ark song GEN/ --target gh2"
    , commandRun = \args opts -> case args of
      [song, gen] -> withProject (optIndex opts) song $ \proj -> do
        targetName <- case [ t | OptTarget t <- opts ] of
          []    -> fatal "command requires --target, none given"
          t : _ -> return t
        target <- case HM.lookup targetName $ _targets $ projectSongYaml proj of
          Nothing     -> fatal $ "Target not found in YAML file: " <> show targetName
          Just target -> return target
        gh2 <- case target of
          GH2 gh2 -> return gh2
          _       -> fatal $ "Target is not for GH2: " <> show targetName
        installGH2 gh2 proj gen
        return [gen]
      _ -> fatal "Expected 2 arguments (input song, GEN)"
    }

  , Command
    { commandWord = "lipsync-midi"
    , commandDesc = "Transfer data from a lipsync file to a MIDI file."
    , commandUsage = "onyx lipsync-midi in.mid in.lipsync [in2.lipsync [in3.lipsync]] out.mid"
    , commandRun = \args _opts -> case args of
      fmid : (unsnoc -> Just (fvocs, fout)) -> do
        stackIO $ testConvertLipsync fmid fvocs fout
        return [fout]
      _ -> fatal "Expected at least 2-5 arguments (input midi, 0-3 input lipsyncs, output midi)"
    }

  , Command
    { commandWord = "lipsync-gen"
    , commandDesc = "Make lipsync files from the vocal tracks in a MIDI file."
    , commandUsage = "onyx lipsync-gen in.mid"
    , commandRun = \args opts -> case args of
      [fmid] -> do
        mid <- RBFile.loadMIDI fmid
        let game = fromMaybe GameRB3 $ listToMaybe [ g | OptGame g <- opts ]
        voxToLip <- case game of
          GameRB3  -> (\vmap -> autoLipsync    defaultTransition vmap englishSyllables) <$> loadVisemesRB3
          GameRB2  -> (\vmap -> autoLipsync    defaultTransition vmap englishSyllables) <$> loadVisemesRB3
          GameTBRB -> (\vmap -> beatlesLipsync defaultTransition vmap englishSyllables) <$> loadVisemesTBRB
          _        -> fatal "Unsupported game for lipsync-gen"
        let template = dropExtension fmid
            tracks =
              [ (RBFile.fixedPartVocals, "_solovox.lipsync", False)
              , (RBFile.fixedHarm1, "_harm1.lipsync", False)
              , (RBFile.fixedHarm2, "_harm2.lipsync", False)
              , (RBFile.fixedHarm3, "_harm3.lipsync", False)
              , (const mempty, "_empty.lipsync", True)
              ]
        fmap catMaybes $ forM tracks $ \(getter, suffix, alwaysWrite) -> do
          let trk = getter $ RBFile.s_tracks mid
              fout = template <> suffix
          if nullVox trk && not alwaysWrite
            then return Nothing
            else do
              let lip = voxToLip $ mapTrack (U.applyTempoTrack $ RBFile.s_tempos mid) trk
              stackIO $ BL.writeFile fout $ runPut $ putLipsync lip
              return $ Just fout
      _ -> fatal "Expected 1 argument (input midi)"
    }

  , Command
    { commandWord = "lipsync-track-gen"
    , commandDesc = "Make lipsync files from LIPSYNC{1,2,3,4} in a MIDI file."
    , commandUsage = "onyx lipsync-track-gen in.mid"
    , commandRun = \args opts -> case args of
      [fmid] -> do
        mid <- RBFile.loadMIDI fmid
        let game = fromMaybe GameRB3 $ listToMaybe [ g | OptGame g <- opts ]
        vmap <- case game of
          GameRB3  -> loadVisemesRB3
          GameRB2  -> loadVisemesRB3
          GameTBRB -> loadVisemesTBRB
          _        -> fatal "Unsupported game for lipsync-track-gen"
        let template = dropExtension fmid
            tracks =
              [ (RBFile.onyxLipsync1, "_1.lipsync")
              , (RBFile.onyxLipsync2, "_2.lipsync")
              , (RBFile.onyxLipsync3, "_3.lipsync")
              , (RBFile.onyxLipsync4, "_4.lipsync")
              ]
            voxToLip
              = (if game == GameTBRB then setBeatles else id)
              . lipsyncFromMIDITrack vmap
        fmap concat $ forM (Map.toList $ RBFile.onyxParts $ RBFile.s_tracks mid) $ \(fpart, opart) -> do
          fmap catMaybes $ forM tracks $ \(getter, suffix) -> do
            let trk = getter opart
                fout = template <> "_" <> T.unpack (RBFile.getPartName fpart) <> suffix
            if trk == mempty
              then return Nothing
              else do
                let lip = voxToLip $ mapTrack (U.applyTempoTrack $ RBFile.s_tempos mid) trk
                stackIO $ BL.writeFile fout $ runPut $ putLipsync lip
                return $ Just fout
      _ -> fatal "Expected 1 argument (input midi)"
    }

  , Command
    { commandWord = "unpref"
    , commandDesc = "Parse a BandSongPref file"
    , commandUsage = "onyx unpref BandSongPref [--to out.txt]"
    , commandRun = \args opts -> case args of
      [fin] -> do
        fout <- outputFile opts $ return $ fin <.> "txt"
        bs <- stackIO $ BL.readFile fin
        pref <- runGetM (codecIn bin) bs
        stackIO $ writeFile fout $ show (pref :: SongPref)
        return [fout]
      _ -> fatal "Expected 1 argument (BandSongPref file)"
    }

  , Command
    { commandWord = "milo"
    , commandDesc = "Recombine a split .milo_xxx file."
    , commandUsage = "onyx milo dir [--to out.milo_xxx]"
    , commandRun = \args opts -> case args of
      [din] -> do
        fout <- outputFile opts $ return $ dropTrailingPathSeparator din <.> "milo_xbox"
        packMilo din fout
        return [fout]
      _ -> fatal "Expected 1 argument (input dir)"
    }

  , Command
    { commandWord = "benchmark-midi"
    , commandDesc = ""
    , commandUsage = "onyx benchmark-midi [raw|fixed|onyx] in.mid [--to out.txt]"
    , commandRun = \args opts -> case args of
      ["raw", fin] -> do
        fout <- outputFile opts $ return $ fin <> ".txt"
        mid <- RBFile.loadMIDI fin
        stackIO $ writeFile fout $ show (mid :: RBFile.Song (RBFile.RawFile U.Beats))
        return [fout]
      ["raw-len", fin] -> do
        fout <- outputFile opts $ return $ fin <> ".txt"
        mid <- RBFile.loadMIDI fin
        stackIO $ writeFile fout $ show $ length $ show (mid :: RBFile.Song (RBFile.RawFile U.Beats))
        return [fout]
      ["fixed", fin] -> do
        fout <- outputFile opts $ return $ fin <> ".txt"
        mid <- RBFile.loadMIDI fin
        stackIO $ writeFile fout $ show (mid :: RBFile.Song (RBFile.FixedFile U.Beats))
        return [fout]
      ["onyx", fin] -> do
        fout <- outputFile opts $ return $ fin <> ".txt"
        mid <- RBFile.loadMIDI fin
        stackIO $ writeFile fout $ show (mid :: RBFile.Song (RBFile.OnyxFile U.Beats))
        return [fout]
      _ -> fatal "Expected 2 arguments (raw/fixed/onyx, then a midi file)"
    }

  , Command
    { commandWord = "scoring"
    , commandDesc = ""
    , commandUsage = T.unlines
      [ "onyx scoring in.mid [players]"
      , "players is a sequence that alternates:"
      , "  part: G B D K V PG PB PD PK H"
      , "  difficulty: e m h x"
      , "for example: onyx scoring in.mid G x B x PD x V x"
      ]
    , commandRun = \args _opts -> case args of
      fin : players -> do
        mid <- RBFile.loadMIDI fin
        case players of
          [] -> stackIO $ forM_ [minBound .. maxBound] $ \scoreTrack -> do
            forM_ [minBound .. maxBound] $ \diff -> do
              let stars = starCutoffs (RBFile.s_tracks mid) [(scoreTrack, diff)]
              when (any (maybe False (> 0)) stars) $ do
                putStrLn $ unwords [show scoreTrack, show diff, show stars]
          _ -> let
            parsePlayers [] = Right []
            parsePlayers [_] = Left "Odd number of player arguments"
            parsePlayers (p : d : rest) = do
              part <- maybe (Left $ "Unrecognized track name: " <> p) Right $ lookup p
                [ (filter (\c -> isUpper c || isDigit c) $ drop 5 $ show strack, strack) | strack <- [minBound .. maxBound] ]
              diff <- maybe (Left $ "Unrecognized difficulty: " <> d) Right $ lookup d
                [("e", Easy), ("m", Medium), ("h", Hard), ("x", Expert)]
              ((part, diff) :) <$> parsePlayers rest
            in case parsePlayers players of
              Left  err   -> fatal err
              Right pairs -> stackIO $ do
                forM_ pairs $ \pair -> let
                  (base, solo) = baseAndSolo (RBFile.s_tracks mid) pair
                  in putStrLn $ show pair <> ": base " <> show base <> ", solo bonuses " <> show solo
                print $ starCutoffs (RBFile.s_tracks mid) pairs
        return []
      _ -> fatal "Expected 1 argument (input midi)"
    }

  , Command
    { commandWord = "black"
    , commandDesc = "Replace the VENUE track in CON MIDIs with a black background."
    , commandUsage = "onyx black con_1 con_2 ..."
    , commandRun = \args _opts -> do
      mapM_ blackVenue args
      return args
    }

  , Command
    { commandWord = "ios"
    , commandDesc = "Extract the contents of a Rock Band iOS, Rock Band Reloaded, or Guitar Hero iOS song."
    , commandUsage = "onyx ios [song.blob|song.iga] ..."
    , commandRun = \args _opts -> fmap concat $ forM args $ \arg -> case takeExtension arg of
      ".blob" -> stackIO $ do
        dec <- IOS.decodeBlob arg
        (blob, dats) <- IOS.loadBlob arg
        let blobDec = arg <.> "dec"
            blobTxt = arg <.> "txt"
        B.writeFile blobDec dec
        writeFile blobTxt $ show blob
        forM_ dats $ \(fout, bs) -> B.writeFile fout bs
        return $ blobDec : blobTxt : fmap fst dats
      ".iga" -> stackIO $ extractIGA arg
      _ -> fatal $ "Unrecognized iOS game file extension: " <> arg
    }

  , Command
    { commandWord = "ark-contents"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args opts -> case args of
      [fin] -> do
        fout <- outputFile opts $ return $ fin <> ".contents.txt"
        arkVersion <- stackIO $ IO.withBinaryFile fin IO.ReadMode $ \h -> runGet getInt32le . BL.fromStrict <$> B.hGet h 4
        case arkVersion of
          2 -> stackIO $ AmpArk.readFileEntries fin >>= writeFile fout . unlines . map show
          3 -> stackIO $ GHArk.readFileEntries fin >>= writeFile fout . unlines . map show
          n -> fail $ "Unsupported ark version: " <> show n
        return [fout]
      _ -> fatal "Expected 1 arg (.hdr, or .ark if none)"
    }

  , Command
    { commandWord = "ark-extract"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args opts -> case args of
      [fin] -> do
        dout <- outputFile opts $ return $ fin <> "_extract"
        arkVersion <- stackIO $ IO.withBinaryFile fin IO.ReadMode $ \h -> runGet getInt32le . BL.fromStrict <$> B.hGet h 4
        (ark, entries) <- case arkVersion of
          2 -> do
            entries <- stackIO $ AmpArk.readFileEntries fin
            return (fin, entries)
          3 -> do
            entries <- stackIO $ GHArk.readFileEntries fin
            return (dropExtension fin <> "_0.ARK", entries)
          n -> fail $ "Unsupported ark version: " <> show n
        stackIO $ Dir.createDirectoryIfMissing False dout
        stackIO $ AmpArk.extractArk entries ark dout
        return [dout]
      _ -> fatal "Expected 1 arg (.hdr, or .ark if none)"
    }

  , Command
    { commandWord = "amp-pack"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args opts -> case args of
      [dir] -> do
        ark <- outputFile opts $ return $ dir <.> "ark"
        stackIO $ AmpArk.createArk dir ark
        return [ark]
      _ -> fatal "Expected 1 arg (folder to make into .ark)"
    }

  , Command
    { commandWord = "gh-pack"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args _opts -> case args of
      [dir, hdr] -> do
        let ark = dropExtension hdr <> "_0.ARK"
        stackIO $ GHArk.createHdrArk dir hdr ark
        return [hdr, ark]
      _ -> fatal "Expected 2 args (folder to pack, .hdr)"
    }

  , Command
    { commandWord = "decode-image"
    , commandDesc = "Converts from HMX image format to PNG."
    , commandUsage = "onyx decode-image input.ext_platform {--to output.png}"
    , commandRun = \args opts -> case args of
      [fin] -> do
        bs <- stackIO $ fmap BL.fromStrict $ B.readFile fin
        case Image.readRBImageMaybe bs of
          Just img -> do
            fout <- outputFile opts $ return $ fin <> ".png"
            stackIO $ writePng fout img
            return [fout]
          Nothing -> fatal "Couldn't decode image file"
      _ -> fatal "Expected 1 arg (HMX image file)"
    }

  , Command
    { commandWord = "coop-max-scores"
    , commandDesc = ""
    , commandUsage = "onyx coop-max-scores notes.mid"
    , commandRun = \args _opts -> case args of
      [fin] -> do
        mid <- RBFile.loadMIDI fin
        let p1 = if nullPart $ gh2PartGuitarCoop $ RBFile.s_tracks mid
              then gh2PartGuitar     $ RBFile.s_tracks mid
              else gh2PartGuitarCoop $ RBFile.s_tracks mid
            p2 = if nullPart $ gh2PartBass $ RBFile.s_tracks mid
              then gh2PartRhythm $ RBFile.s_tracks mid
              else gh2PartBass   $ RBFile.s_tracks mid
            scores1 = map (\diff -> gh2Base diff p1) [Easy .. Expert]
            scores2 = map (\diff -> gh2Base diff p2) [Easy .. Expert]
            scoresCoop = map (\diff -> gh2Base diff p1 + gh2Base diff p2) [Easy .. Expert]
            dta scores = "(" <> unwords (map show scores) <> ")"
        lg $ "p1: " <> dta scores1
        lg $ "p2: " <> dta scores2
        lg $ "coop: " <> dta scoresCoop
        return []
      _ -> fatal "Expected 1 arg (midi)"
    }

  , Command
    { commandWord = "import-audio"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args opts -> case args of
      audios@(_ : _) -> do
        pairs <- forM audios $ \audio -> inside ("audio file: " <> audio) $ do
          md5 <- audioMD5 audio >>= maybe (fatal "Couldn't compute audio hash") return
          len <- audioLength audio >>= maybe (fatal "Couldn't compute audio length") return
          return (md5, len)
        dir <- outputFile opts $ return "."
        stackIO $ Dir.createDirectoryIfMissing False dir
        stackIO $ yamlEncodeFile (dir </> "song.yml") $ toJSON (SongYaml
          { _metadata = def
          , _global   = def
          , _audio    = HM.fromList $ flip map (zip [1..] pairs) $ \(i, (md5, len)) -> let
            ainfo = AudioFile AudioInfo
              { _md5      = Just $ T.pack md5
              , _frames   = Just len
              , _filePath = Nothing
              , _commands = []
              , _rate     = Nothing
              , _channels = 2 -- TODO real channel count from audio
              }
            in (T.pack $ "audio-" <> show (i :: Int), ainfo)
          , _jammit   = HM.empty
          , _plans    = HM.singleton "plan" Plan
            { _song         = Just PlanAudio
              { _planExpr = Input $ Named "audio-1"
              , _planPans = []
              , _planVols = []
              }
            , _countin      = Countin []
            , _planParts    = Parts HM.empty
            , _crowd        = Nothing
            , _planComments = []
            , _tuningCents  = 0
            , _fileTempo    = Nothing
            }
          , _targets  = HM.empty
          , _parts    = Parts HM.empty
          } :: SongYaml FilePath)
        return [dir]
      _ -> fatal "Expected at least 1 arg (flac or wav files)"
    }

  , Command
    { commandWord = "decrypt-wor"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args opts -> forM args $ \xen -> do
      enc <- stackIO $ B.readFile xen
      dec <- case aesDecrypt enc of
        Nothing  -> case stripSuffix ".fsb.xen" (takeFileName xen) >>= \base -> fsbDecrypt base enc of
          Nothing  -> fatal "Couldn't decrypt GH .fsb.xen audio"
          Just dec -> return dec
        Just dec -> return dec
      out <- outputFile opts $ return $ case stripSuffix ".fsb.xen" xen of
        Just root -> root <.> "fsb"
        Nothing   -> xen <.> "fsb"
      stackIO $ B.writeFile out dec
      return out
    }

  , Command
    { commandWord = "encrypt-wor"
    , commandDesc = "Use the encryption key from one .fsb.xen file to make a new one."
    , commandUsage = "onyx encrypt-wor original.fsb.xen new.fsb [--to new.fsb.xen]"
    , commandRun = \args opts -> case args of
      [base, fsb] -> do
        base' <- stackIO $ B.readFile base
        fsb' <- stackIO $ B.readFile fsb
        case aesEncrypt base' fsb' of
          Nothing -> fatal "Couldn't encrypt into .fsb.xen"
          Just xen -> do
            out <- outputFile opts $ return $ fsb <.> "xen"
            stackIO $ B.writeFile out xen
            return [out]
      _ -> fatal "Expected 2 arguments (original.fsb.xen and new.fsb)"
    }

  , Command
    { commandWord = "extract-pak"
    , commandDesc = ""
    , commandUsage = "onyx extract-pak in.pak.xen [--to out-folder]"
    , commandRun = \args opts -> case args of
      [pak] -> inside ("extracting pak " <> pak) $ do
        dout <- outputFile opts $ return $ pak <> "_extract"
        stackIO $ Dir.createDirectoryIfMissing False dout
        nodes <- stackIO $ splitPakNodes <$> BL.readFile pak
        stackIO $ writeFile (dout </> "pak-contents.txt") $ unlines $ map (show . fst) nodes
        let knownExts =
              [ ".cam", ".clt", ".col", ".dbg", ".empty", ".fam", ".fnc", ".fnt", ".fnv"
              , ".gap", ".hkc", ".img", ".imv", ".jam", ".last", ".mcol", ".mdl", ".mdv"
              , ".mqb", ".nav", ".note", ".nqb", ".oba", ".perf", ".pfx", ".pimg", ".pimv"
              , ".qb", ".qd", ".qs", ".qs.br", ".qs.de", ".qs.en", ".qs.es", ".qs.fr", ".qs.it"
              , ".rag", ".raw", ".rgn", ".rnb", ".scn", ".scv", ".shd", ".ska", ".ske", ".skin"
              , ".skiv", ".snp", ".sqb", ".stat", ".stex", ".table", ".tex", ".trkobj", ".tvx", ".wav", ".xml"
              ]
        forM_ (zip [0..] nodes) $ \(i, (node, contents)) -> do
          let ext = fromMaybe ("." <> show (nodeFileType node))
                $ find ((== nodeFileType node) . qbKeyCRC . B8.pack) knownExts
              name = reverse (take 3 $ reverse (show (i :: Int)) <> repeat '0') <> ext
          stackIO $ BL.writeFile (dout </> name) contents
          when (nodeFileType node == qbKeyCRC ".note") $ do
            -- TODO handle failure
            note <- loadNoteFile contents
            stackIO $ writeFile (dout </> name <.> "parsed.txt") $ show note
          when (nodeFileType node == qbKeyCRC ".qb") $ do
            let matchingQS = flip filter nodes $ \(otherNode, _) ->
                  nodeFilenameCRC node == nodeFilenameCRC otherNode
                    && nodeFileType otherNode == qbKeyCRC ".qs.en"
                mappingQS = qsBank matchingQS
            inside ("Parsing QB file: " <> show name) $ do
              mqb <- errorToWarning $ runGetM parseQB contents
              forM_ mqb $ \qb -> do
                let filled = map (lookupQB knownKeys . lookupQS mappingQS) qb
                stackIO $ Y.encodeFile (dout </> name <.> "parsed.yaml") filled
        return [dout]
      _ -> fatal "Expected 1 argument (_song.pak.xen)"
    }

  , Command
    { commandWord = "rebuild-pak"
    , commandDesc = ""
    , commandUsage = "onyx rebuild-pak in-folder [--to out.pak.xen]"
    , commandRun = \args opts -> case args of
      [dir] -> do
        fout <- outputFile opts $ return $ dir <.> "pak"
        contents <- stackIO $ readFile $ dir </> "pak-contents.txt"
        let nodes = map read $ lines contents
        files <- stackIO $ Dir.listDirectory dir
        let fileMap = Map.fromList $ do
              f <- files
              n <- toList $ readMaybe $ takeWhile isDigit f
              guard $ not $ ".parsed." `T.isInfixOf` T.pack f
              return (n, f)
        newContents <- forM (zip [0..] nodes) $ \(i, node) -> case Map.lookup (i :: Int) fileMap of
          Just f -> do
            bs <- stackIO $ BL.fromStrict <$> B.readFile (dir </> f)
            return (node, bs)
          Nothing -> fatal $ "Couldn't find pak content #" <> show i
        stackIO $ BL.writeFile fout $ buildPak newContents
        return [fout]
      _ -> fatal "Expected 1 argument (extracted .pak folder)"
    }

  , Command
    { commandWord = "make-qb"
    , commandDesc = "Compile a .yaml file back into a .qb"
    , commandUsage = "onyx make-qb in.qb.parsed.yaml [--to out.qb]"
    , commandRun = \args opts -> case args of
      [fin] -> do
        fout <- outputFile opts $ return $ fin <.> "qb"
        qb <- stackIO (Y.decodeFileEither fin) >>= either (\e -> fatal $ show e) return
        stackIO $ BL.writeFile fout $ putQB $ discardStrings qb
        return [fout]
      _ -> fatal "Expected 1 argument (.yaml)"
    }

  , Command
    { commandWord = "share-wor"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args _opts -> do
      shareMetadata args
      return args
    }

  , Command
    { commandWord = "make-wor-database"
    , commandDesc = ""
    , commandUsage = ""
    , commandRun = \args opts -> do
      fout <- outputFile opts $ fatal "make-wor-database requires --to argument"
      makeMetadataLIVE args fout
      return [fout]
    }

  ]

runDolphin
  :: (MonadResource m, SendMessage m)
  => [FilePath] -- ^ CONs
  -> Maybe (RBFile.Song (RBFile.FixedFile U.Beats) -> RBFile.Song (RBFile.FixedFile U.Beats)) -- ^ MIDI transform
  -> Bool -- ^ Try to make preview audio?
  -> FilePath -- ^ output dir
  -> StackTraceT m [FilePath] -- ^ 2 .app files
runDolphin cons midfn makePreview out = do
  stackIO $ Dir.createDirectoryIfMissing False out
  let out_meta = out </> "00000001.app"
      out_song = out </> "00000002.app"
  tempDir "onyx_dolphin" $ \temp -> do
    let extract  = temp </> "extract"
        dir_meta = temp </> "meta"
        dir_song = temp </> "song"
    allSongs <- fmap concat $ forM cons $ \stfs -> do
      lg $ "STFS: " <> stfs
      stackIO $ Dir.createDirectory extract
      stackIO $ extractSTFS stfs extract
      songs <- readFileSongsDTA $ extract </> "songs/songs.dta"
      prevEnds <- forM songs $ \(song, _) -> do
        let DTASingle _ pkg _ = song
            songsXX = T.unpack $ D.songName $ D.song pkg
            songsXgen = takeDirectory songsXX </> "gen"
            songsXgenX = songsXgen </> takeFileName songsXX
        lg $ "Song: " <> T.unpack (D.name pkg) <> maybe "" (\artist -> " (" <> T.unpack artist <> ")") (D.artist pkg)
        stackIO $ Dir.createDirectoryIfMissing True $ dir_meta </> "content" </> songsXgen
        stackIO $ Dir.createDirectoryIfMissing True $ dir_song </> "content" </> songsXgen
        -- .mid (use unchanged, or edit to remove fills and/or mustang PG)
        let midin  = extract </> songsXX <.> "mid"
            midout = dir_song </> "content" </> songsXX <.> "mid"
        case midfn of
          Nothing -> stackIO $ Dir.copyFile midin midout
          Just f  -> do
            mid <- RBFile.loadMIDI midin
            stackIO $ Save.toFile midout $ RBFile.showMIDIFile' $ f mid
        -- .mogg (use unchanged)
        let mogg = dir_song </> "content" </> songsXX <.> "mogg"
        stackIO $ Dir.renameFile (extract </> songsXX <.> "mogg") mogg
        -- _prev.mogg (generate if possible)
        let ogg = extract </> "temp.ogg"
            prevOgg = extract </> "temp_prev.ogg"
            (prevStart, prevEnd) = D.preview pkg
            prevLength = min 15000 $ prevEnd - prevStart
            silentPreview = stackIO
              $ runResourceT
              $ sinkSnd prevOgg (Snd.Format Snd.HeaderFormatOgg Snd.SampleFormatVorbis Snd.EndianFile)
              $ (CA.silent (CA.Seconds $ realToFrac prevLength / 1000) 44100 2 :: CA.AudioSource (ResourceT IO) Int16)
        if makePreview
          then errorToEither (moggToOgg mogg ogg) >>= \case
            Right () -> do
              lg "Creating preview file"
              src <- stackIO $ sourceSndFrom (CA.Seconds $ realToFrac prevStart / 1000) ogg
              stackIO
                $ runResourceT
                $ sinkSnd prevOgg (Snd.Format Snd.HeaderFormatOgg Snd.SampleFormatVorbis Snd.EndianFile)
                $ fadeStart (CA.Seconds 0.75)
                $ fadeEnd (CA.Seconds 0.75)
                $ CA.takeStart (CA.Seconds $ realToFrac prevLength / 1000)
                $ applyPansVols (D.pans $ D.song pkg) (D.vols $ D.song pkg)
                $ src
            Left _msgs -> do
              lg "Encrypted audio, skipping preview"
              silentPreview
          else silentPreview
        oggToMogg prevOgg $ dir_meta </> "content" </> (songsXX ++ "_prev.mogg")
        -- .png_wii (convert from .png_xbox)
        img <- stackIO $ pixelMap dropTransparency . Image.readRBImage . BL.fromStrict <$> B.readFile (extract </> (songsXgenX ++ "_keep.png_xbox"))
        stackIO $ BL.writeFile (dir_meta </> "content" </> (songsXgenX ++ "_keep.png_wii")) $ Image.toDXT1File Image.PNGWii img
        -- .milo_wii (copy)
        stackIO $ Dir.renameFile (extract </> songsXgenX <.> "milo_xbox") (dir_song </> "content" </> songsXgenX <.> "milo_wii")
        -- return new preview end time to put in .dta
        return $ prevStart + prevLength
      stackIO $ Dir.removeDirectoryRecursive extract
      return $ zip songs prevEnds
    -- write new combined dta file
    lg "Writing combined songs.dta"
    let dta = dir_meta </> "content/songs/songs.dta"
    stackIO $ Dir.createDirectoryIfMissing True $ takeDirectory dta
    stackIO $ B.writeFile dta $ TE.encodeUtf8 $ T.unlines $ do
      ((DTASingle key pkg c3, _), prevEnd) <- allSongs
      let pkg' = pkg
            { D.song = (D.song pkg)
              { D.songName = "dlc/sZAE/001/content/" <> D.songName (D.song pkg)
              }
            , D.encoding = Just "utf8"
            , D.preview = (fst $ D.preview pkg, prevEnd)
            }
      return $ writeDTASingle $ DTASingle key pkg' c3
    -- pack it all up
    lg "Packing into U8 files"
    stackIO $ packU8 dir_meta out_meta
    stackIO $ packU8 dir_song out_song
  return [out_meta, out_song]

commandLine :: (MonadResource m) => [String] -> StackTraceT (QueueLog m) [FilePath]
commandLine args = let
  (opts, nonopts, errors) = getOpt Permute optDescrs args
  printIntro = lg $ T.unpack $ T.unlines
    [ "Onyx Music Game Toolkit"
    , ""
    , "Usage: onyx [command] [files] [options]"
    , "Commands: " <> T.unwords (map commandWord commands)
    , "Run `onyx [command] --help` for further instructions."
    , ""
    ]
  in case errors of
    [] -> case nonopts of
      [] -> if elem OptHelp opts
        then printIntro >> return []
        else printIntro >> fatal "No command given."
      cmd : nonopts' -> case [ c | c <- commands, commandWord c == T.pack cmd ] of
        [c] -> inside ("command: onyx " <> cmd) $ if elem OptHelp opts
          then do
            lg $ T.unpack $ T.unlines
              [ "onyx " <> commandWord c
              , commandDesc c
              , ""
              , "Usage:"
              , commandUsage c
              ]
            return []
          else commandRun c nonopts' opts
        _ -> printIntro >> fatal ("Unrecognized command: " ++ show cmd)
    _ -> inside "command line parsing" $ do
      printIntro
      throwError $ Messages [ Message e [] | e <- errors ]

optDescrs :: [OptDescr OnyxOption]
optDescrs =
  [ Option []   ["target"         ] (ReqArg (OptTarget . T.pack)   "TARGET"   ) ""
  , Option []   ["plan"           ] (ReqArg (OptPlan   . T.pack)   "PLAN"     ) ""
  , Option []   ["to"             ] (ReqArg OptTo                  "PATH"     ) ""
  , Option []   ["2x"             ] (ReqArg Opt2x                  "PATH"     ) ""
  , Option []   ["game"           ] (ReqArg (OptGame . readGame)   "{rb3,rb2}") ""
  , Option []   ["separate-lines" ] (NoArg  OptSeparateLines                  ) ""
  , Option []   ["in-beats"       ] (NoArg  OptInBeats                        ) ""
  , Option []   ["in-seconds"     ] (NoArg  OptInSeconds                      ) ""
  , Option []   ["in-measures"    ] (NoArg  OptInMeasures                     ) ""
  , Option []   ["match-notes"    ] (NoArg  OptMatchNotes                     ) ""
  , Option []   ["resolution"     ] (ReqArg (OptResolution . read) "int"      ) ""
  , Option []   ["speed"          ] (ReqArg (OptSpeed . read)      "real"     ) ""
  , Option []   ["rb2-version"    ] (NoArg  OptRB2Version                     ) ""
  , Option []   ["wii-no-fills"   ] (NoArg  OptWiiNoFills                     ) ""
  , Option []   ["wii-mustang-22" ] (NoArg  OptWiiMustang22                   ) ""
  , Option []   ["wii-unmute-22"  ] (NoArg  OptWiiUnmute22                    ) ""
  , Option []   ["venuegen"       ] (NoArg  OptVenueGen                       ) ""
  , Option []   ["index"          ] (ReqArg (OptIndex . read)      "int"      ) ""
  , Option "h?" ["help"           ] (NoArg  OptHelp                           ) ""
  ] where
    readGame = \case
      "rb3"  -> GameRB3
      "rb2"  -> GameRB2
      "tbrb" -> GameTBRB
      "gh2"  -> GameGH2
      "ghwor" -> GameGHWOR
      g      -> error $ "Unrecognized --game value: " ++ show g

data OnyxOption
  = OptTarget T.Text
  | OptPlan T.Text
  | OptTo FilePath
  | Opt2x FilePath
  | OptGame Game
  | OptSeparateLines
  | OptInBeats
  | OptInSeconds
  | OptInMeasures
  | OptResolution Integer
  | OptMatchNotes
  | OptSpeed Double
  | OptRB2Version
  | OptWiiNoFills
  | OptWiiMustang22
  | OptWiiUnmute22
  | OptVenueGen
  | OptIndex Int
  | OptHelp
  deriving (Eq, Ord, Show)

applyMidiFunction
  :: (MonadIO m, SendMessage m)
  => Maybe (RBFile.Song (RBFile.FixedFile U.Beats) -> RBFile.Song (RBFile.FixedFile U.Beats)) -- ^ MIDI transform
  -> FilePath
  -> FilePath
  -> StackTraceT m ()
applyMidiFunction Nothing fin fout = stackIO $ Dir.copyFile fin fout
applyMidiFunction (Just fn) fin fout = do
  mid <- RBFile.loadMIDI fin
  stackIO $ Save.toFile fout $ RBFile.showMIDIFile' $ fn mid

getDolphinFunction
  :: [OnyxOption]
  -> Maybe (RBFile.Song (RBFile.FixedFile U.Beats) -> RBFile.Song (RBFile.FixedFile U.Beats))
getDolphinFunction opts = let
  nofills   = elem OptWiiNoFills   opts
  mustang22 = elem OptWiiMustang22 opts
  unmute22  = elem OptWiiUnmute22  opts
  in do
    guard $ or [nofills, mustang22, unmute22]
    Just
      $ (if nofills   then RBFile.wiiNoFills   else id)
      . (if mustang22 then RBFile.wiiMustang22 else id)
      . (if unmute22  then RBFile.wiiUnmute22  else id)

data Game
  = GameRB3
  | GameRB2
  | GameTBRB
  | GameGH2
  | GameGHWOR
  deriving (Eq, Ord, Show)

midiOptions :: [OnyxOption] -> MS.Options
midiOptions opts = MS.Options
  { MS.showFormat = if
    | elem OptInBeats opts -> MS.ShowBeats
    | elem OptInSeconds opts -> MS.ShowSeconds
    | elem OptInMeasures opts -> MS.ShowMeasures
    | otherwise -> MS.ShowBeats
  , MS.resolution = Just $ fromMaybe 480 $ listToMaybe [ r | OptResolution r <- opts ]
  , MS.separateLines = elem OptSeparateLines opts
  , MS.matchNoteOff = elem OptMatchNotes opts
  }

blackVenue :: (SendMessage m, MonadIO m) => FilePath -> StackTraceT m ()
blackVenue fcon = inside ("Inserting black VENUE in: " <> fcon) $ do
  (hdr, meta) <- stackIO $ withSTFSPackage fcon $ \pkg -> return (stfsHeader pkg, stfsMetadata pkg)
  topFolder <- stackIO $ getSTFSFolder fcon
  isRB3 <- case findFileCI ("songs" :| pure "songs.dta") topFolder of
    Nothing -> fatal "Couldn't find songs.dta in package"
    Just r  -> do
      dtaBS <- stackIO $ useHandle r handleToByteString
      songs <- readDTASingles $ BL.toStrict dtaBS
      case map (D.songFormat . dtaSongPackage . fst) songs of
        [] -> fatal "No songs found in songs.dta"
        fmts  | all (>= 10) fmts -> return True
              | all (< 10) fmts -> return False
              | otherwise -> fatal
                "Mix of RB3 and pre-RB3 songs found in pack (???)"
  let updateMids folder = do
        newFiles <- forM (folderFiles folder) $ \(name, r) -> do
          r' <- if ".mid" `T.isSuffixOf` name
            then do
              bs <- stackIO $ useHandle r handleToByteString
              F.Cons typ dvn trks <- inside ("loading " <> T.unpack name) $ do
                (mid, warns) <- runGetM getMIDI bs
                mapM_ warn warns
                return mid
              -- TODO this does not yet handle official-format (milo venue) songs
              let black = U.setTrackName "VENUE" $ if isRB3
                    then RTB.fromPairList $ map (\s -> (0, E.MetaEvent $ Meta.TextEvent s))
                      ["[lighting (blackout_fast)]", "[film_b+w.pp]", "[coop_all_far]"]
                    else Wait 0 (E.MetaEvent $ Meta.TextEvent "[verse]")
                      $ Wait 0 (E.MetaEvent $ Meta.TextEvent "[lighting (blackout_fast)]")
                      $ Wait 0 (makeEdgeCPV 0 60 $ Just 96) -- camera cut
                      $ Wait 0 (makeEdgeCPV 0 61 $ Just 96) -- focus bass
                      $ Wait 0 (makeEdgeCPV 0 62 $ Just 96) -- focus drums
                      $ Wait 0 (makeEdgeCPV 0 63 $ Just 96) -- focus guitar
                      $ Wait 0 (makeEdgeCPV 0 64 $ Just 96) -- focus vocal
                      $ Wait 0 (makeEdgeCPV 0 71 $ Just 96) -- only far
                      $ Wait 0 (makeEdgeCPV 0 108 $ Just 96) -- video_bw
                      $ Wait 120 (makeEdgeCPV 0 60 Nothing)
                      $ Wait 0 (makeEdgeCPV 0 61 Nothing)
                      $ Wait 0 (makeEdgeCPV 0 62 Nothing)
                      $ Wait 0 (makeEdgeCPV 0 63 Nothing)
                      $ Wait 0 (makeEdgeCPV 0 64 Nothing)
                      $ Wait 0 (makeEdgeCPV 0 71 Nothing)
                      $ Wait 0 (makeEdgeCPV 0 108 Nothing) RNil
                  isVenue = (== Just "VENUE") . U.trackName
                  mid = F.Cons typ dvn $ filter (not . isVenue) trks ++ [black]
              return $ makeHandle ("Black VENUE output for " <> T.unpack name)
                $ byteStringSimpleHandle $ Save.toByteString mid
            else return r
          return (name, r')
        newSubs <- forM (folderSubfolders folder) $ \(name, sub) -> do
          sub' <- updateMids sub
          return (name, sub')
        return Folder
          { folderFiles = newFiles
          , folderSubfolders = newSubs
          }
  topFolder' <- updateMids topFolder
  let opts = CreateOptions
        { createNames         = md_DisplayName meta
        , createDescriptions  = md_DisplayDescription meta
        , createTitleID       = md_TitleID meta
        , createTitleName     = md_TitleName meta
        , createThumb         = md_ThumbnailImage meta
        , createTitleThumb    = md_TitleThumbnailImage meta
        , createLicenses      = [LicenseEntry (-1) 1 0] -- unlocked
        , createMediaID       = 0
        , createVersion       = 0
        , createBaseVersion   = 0
        , createTransferFlags = 0xC0
        , createLIVE          = case hdr of CON{} -> False; _ -> True
        }
      ftemp = fcon <> ".tmp"
  stackIO $ makeCONReadable opts topFolder' ftemp
  stackIO $ Dir.renameFile ftemp fcon
