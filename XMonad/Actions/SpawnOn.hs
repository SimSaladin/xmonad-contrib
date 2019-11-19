{-# LANGUAGE DeriveDataTypeable #-}
-----------------------------------------------------------------------------
-- |
-- Module       : XMonad.Actions.SpawnOn
-- Copyright    : (c) Spencer Janssen
-- License      : BSD
--
-- Maintainer   : Spencer Janssen <spencerjanssen@gmail.com>
-- Stability    : unstable
-- Portability  : unportable
--
-- Provides a way to modify a window spawned by a command(e.g shift it to the workspace
-- it was launched on) by using the _NET_WM_PID property that most windows set on creation.
-- Hence this module won't work on applications that don't set this property.
--
-----------------------------------------------------------------------------

module XMonad.Actions.SpawnOn (
    -- * Usage
    -- $usage
    Spawner,
    manageSpawn,
    manageSpawnWithGC,
    spawnHere,
    spawnOn,
    spawnAndDo,
    shellPromptHere,
    shellPromptOn,
    manageByPPID
) where

import Control.Exception (tryJust)
import Control.Monad (guard)
import Data.List (find, isPrefixOf, isInfixOf)
import Data.Maybe (isJust)
import System.IO.Error (isDoesNotExistError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Types (ProcessID)
import Text.Printf (printf)

import XMonad
import qualified XMonad.StackSet as W

import XMonad.Hooks.ManageHelpers
import XMonad.Prompt
import XMonad.Prompt.Shell
import qualified XMonad.Util.ExtensibleState as XS

-- $usage
-- You can use this module with the following in your @~\/.xmonad\/xmonad.hs@:
--
-- >    import XMonad.Actions.SpawnOn
--
-- >    main = do
-- >      xmonad def {
-- >         ...
-- >         manageHook = manageSpawn <+> manageHook def
-- >         ...
-- >      }
--
-- To ensure that application appears on a workspace it was launched at, add keybindings like:
--
-- >  , ((mod1Mask,xK_o), spawnHere "urxvt")
-- >  , ((mod1Mask,xK_s), shellPromptHere def)
--
-- The module can also be used to apply other manage hooks to the window of
-- the spawned application(e.g. float or resize it).
--
-- For detailed instructions on editing your key bindings, see
-- "XMonad.Doc.Extending#Editing_key_bindings".

newtype Spawner = Spawner {pidsRef :: [(ProcessID, ManageHook)]} deriving Typeable

instance ExtensionClass Spawner where
    initialValue = Spawner []


getPPIDOf :: ProcessID -> Maybe ProcessID
getPPIDOf pid =
    case unsafePerformIO . tryJust (guard . isDoesNotExistError) . readFile . printf "/proc/%d/status" $ toInteger pid of
      Left _         -> Nothing
      Right contents -> do
        line <- find (isPrefixOf "PPid:") $ lines contents
        case words line of
             _ : ppid : _ -> Just $ fromIntegral (read ppid :: Int)
             _            -> Nothing

getPPIDChain :: ProcessID -> [ProcessID]
getPPIDChain pid' = pid' : ppid_chain pid'
    where ppid_chain pid =
              if pid == 0
              then []
              else case getPPIDOf pid of
                     Nothing   -> []
                     Just ppid -> ppid : ppid_chain ppid

-- | Get the current Spawner or create one if it doesn't exist.
modifySpawner :: ([(ProcessID, ManageHook)] -> [(ProcessID, ManageHook)]) -> X ()
modifySpawner f = XS.modify (Spawner . f . pidsRef)

-- | Provides a manage hook to react on process spawned with
-- 'spawnOn', 'spawnHere' etc.
manageSpawn :: ManageHook
manageSpawn = manageSpawnWithGC (return . take 20)

manageSpawnWithGC :: ([(ProcessID, ManageHook)] -> X [(ProcessID, ManageHook)])
        -- ^ function to stop accumulation of entries for windows that never set @_NET_WM_PID@
       -> ManageHook
manageSpawnWithGC garbageCollect = do
    Spawner pids <- liftX XS.get
    mp <- pid
    let ppid_chain = case mp of
                       Just winpid -> winpid : getPPIDChain winpid
                       Nothing     -> []
        known_window_handlers = [ mh
                                | ppid <- ppid_chain
                                , let mpid = lookup ppid pids
                                , isJust mpid
                                , let (Just mh) = mpid ]
    case known_window_handlers of
        [] -> idHook
        (mh:_)  -> do
            whenJust mp $ \p -> liftX $ do
                ps <- XS.gets pidsRef
                XS.put . Spawner =<< garbageCollect (filter ((/= p) . fst) ps)
            mh

mkPrompt :: (String -> X ()) -> XPConfig -> X ()
mkPrompt cb c = do
    cmds <- io $ getCommands
    mkXPrompt Shell c (getShellCompl cmds $ searchPredicate c) cb

-- | Replacement for Shell prompt ("XMonad.Prompt.Shell") which launches
-- application on current workspace.
shellPromptHere :: XPConfig -> X ()
shellPromptHere = mkPrompt spawnHere

-- | Replacement for Shell prompt ("XMonad.Prompt.Shell") which launches
-- application on given workspace.
shellPromptOn :: WorkspaceId -> XPConfig -> X ()
shellPromptOn ws = mkPrompt (spawnOn ws)

-- | Replacement for 'spawn' which launches
-- application on current workspace.
spawnHere :: String -> X ()
spawnHere cmd = withWindowSet $ \ws -> spawnOn (W.currentTag ws) cmd

-- | Replacement for 'spawn' which launches
-- application on given workspace.
spawnOn :: WorkspaceId -> String -> X ()
spawnOn ws cmd = spawnAndDo (doShift ws) cmd

-- | Spawn an application and apply the manage hook when it opens.
spawnAndDo :: ManageHook -> String -> X ()
spawnAndDo mh cmd = do
    p <- spawnPID $ mangle cmd
    modifySpawner $ ((p,mh) :)
 where
    -- TODO this is silly, search for a better solution
    mangle xs | any (`elem` metaChars) xs || "exec" `isInfixOf` xs = xs
              | otherwise = "exec " ++ xs
    metaChars = "&|;"

-- | @manageByPPID 0 idHook@
manageByPPID :: ProcessID -> ManageHook -> X ()
manageByPPID pid mh = modifySpawner ((pid,mh):)
