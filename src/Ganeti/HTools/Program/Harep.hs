{-# LANGUAGE TupleSections #-}

{-| Auto-repair tool for Ganeti.

-}

{-

Copyright (C) 2013 Google Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-}

module Ganeti.HTools.Program.Harep
  ( main
  , arguments
  , options) where

import Control.Exception (bracket)
import Control.Lens (over)
import Control.Monad
import Data.Maybe
import System.Time
import qualified Data.Map as Map
import qualified Text.JSON as J

import Ganeti.BasicTypes
import Ganeti.Common
import Ganeti.Errors
import Ganeti.JQueue (currentTimestamp, reasonTrailTimestamp)
import Ganeti.JQueue.Objects (Timestamp)
import Ganeti.Jobs
import Ganeti.OpCodes
import Ganeti.OpCodes.Lens (metaParamsL, opReasonL)
import Ganeti.Types
import Ganeti.Utils
import qualified Ganeti.Luxi as L
import qualified Ganeti.Path as Path

import Ganeti.HTools.CLI
import qualified Ganeti.HTools.Container as Container
import Ganeti.HTools.Loader
import Ganeti.HTools.ExtLoader
import Ganeti.HTools.Repair
import Ganeti.HTools.Types
import qualified Ganeti.HTools.Instance as Instance

import Ganeti.Version (version)


-- | Options list and functions.
options :: IO [OptType]
options = do
  luxi <- oLuxiSocket
  return
    [ luxi
    , oJobDelay
    , oReason
    , oDryRun
    ]

arguments :: [ArgCompletion]
arguments = []

-- | Wraps an 'OpCode' in a 'MetaOpCode' while also adding a comment
-- about what generated the opcode.
annotateOpCode :: Maybe String -> Timestamp -> OpCode -> MetaOpCode
annotateOpCode reason ts =
  over (metaParamsL . opReasonL)
      (++ [( "harep", fromMaybe ("harep " ++ version ++ " called") reason
           , reasonTrailTimestamp ts)])
  . setOpComment ("automated repairs by harep " ++ version)
  . wrapOpCode

-- | Query jobs of a pending repair, returning the new instance data.
processPending :: Options -> L.Client -> InstanceData -> IO InstanceData
processPending opts client instData =
  case arState instData of
    (ArPendingRepair arData) -> do
      sts <- L.queryJobsStatus client $ arJobs arData
      time <- getClockTime
      case sts of
        Bad e -> exitErr $ "could not check job status: " ++ formatError e
        Ok sts' ->
          if any (<= JOB_STATUS_RUNNING) sts' then
            return instData -- (no change)
          else do
            let iname = Instance.name $ arInstance instData
                srcSt = arStateName $ arState instData
                destSt = arStateName arState'
            putStrLn ("Moving " ++ iname ++ " from " ++ show srcSt ++ " to " ++
                      show destSt)
            commitChange opts client instData'
          where
            instData' =
              instData { arState = arState'
                       , tagsToRemove = delCurTag instData
                       }
            arState' =
              if all (== JOB_STATUS_SUCCESS) sts' then
                ArHealthy $ Just (updateTag $ arData { arResult = Just ArSuccess
                                                     , arTime = time })
              else
                ArFailedRepair (updateTag $ arData { arResult = Just ArFailure
                                                   , arTime = time })

    _ -> return instData

-- | Apply and remove tags from an instance as indicated by 'InstanceData'.
--
-- If the /arState/ of the /InstanceData/ record has an associated
-- 'AutoRepairData', add its tag to the instance object. Additionally, if
-- /tagsToRemove/ is not empty, remove those tags from the instance object. The
-- returned /InstanceData/ object always has an empty /tagsToRemove/.
commitChange :: Options -> L.Client -> InstanceData -> IO InstanceData
commitChange opts client instData = do
  now <- currentTimestamp
  let iname = Instance.name $ arInstance instData
      arData = getArData $ arState instData
      rmTags = tagsToRemove instData
      execJobsWaitOk' opcodes = unless (optDryRun opts) $ do
        res <- execJobsWaitOk
                 [map (annotateOpCode (optReason opts) now) opcodes] client
        case res of
          Ok _ -> return ()
          Bad e -> exitErr e

  when (isJust arData) $ do
    let tag = arTag $ fromJust arData
    putStrLn (">>> Adding the following tag to " ++ iname ++ ":\n" ++ show tag)
    execJobsWaitOk' [OpTagsSet TagKindInstance [tag] (Just iname)]

  unless (null rmTags) $ do
    putStr (">>> Removing the following tags from " ++ iname ++ ":\n" ++
            unlines (map show rmTags))
    execJobsWaitOk' [OpTagsDel TagKindInstance rmTags (Just iname)]

  return instData { tagsToRemove = [] }

-- | Submit jobs, unless a dry-run is requested; in this case, just report
-- the job that would be submitted.
submitJobs' :: Options -> [[MetaOpCode]] -> L.Client -> IO (Result [JobId])
submitJobs' opts jobs client =
  if optDryRun opts
    then do
      putStrLn . (++) "jobs: " . J.encode $ map (map metaOpCode) jobs
      return $ Ok []
    else
      submitJobs jobs client

-- | Perform the suggested repair on an instance if its policy allows it.
doRepair :: Options
         -> L.Client     -- ^ The Luxi client
         -> Double       -- ^ Delay to insert before the first repair opcode
         -> InstanceData -- ^ The instance data
         -> (AutoRepairType, [OpCode]) -- ^ The repair job to perform
         -> IO InstanceData -- ^ The updated instance data
doRepair opts client delay instData (rtype, opcodes) =
  let inst = arInstance instData
      ipol = Instance.arPolicy inst
      iname = Instance.name inst
  in
  case ipol of
    ArEnabled maxtype ->
      if rtype > maxtype then do
        uuid <- newUUID
        time <- getClockTime

        let arState' = ArNeedsRepair (
              updateTag $ AutoRepairData rtype uuid time [] (Just ArEnoperm) "")
            instData' = instData { arState = arState'
                                 , tagsToRemove = delCurTag instData
                                 }

        putStrLn ("Not performing a repair of type " ++ show rtype ++ " on " ++
          iname ++ " because only repairs up to " ++ show maxtype ++
          " are allowed")
        commitChange opts client instData'  -- Adds "enoperm" result label.
      else do
        now <- currentTimestamp
        putStrLn ("Executing " ++ show rtype ++ " repair on " ++ iname)

        -- After submitting the job, we must write an autorepair:pending tag,
        -- that includes the repair job IDs so that they can be checked later.
        -- One problem we run into is that the repair job immediately grabs
        -- locks for the affected instance, and the subsequent TAGS_SET job is
        -- blocked, introducing an unnecessary delay for the end-user. One
        -- alternative would be not to wait for the completion of the TAGS_SET
        -- job, contrary to what commitChange normally does; but we insist on
        -- waiting for the tag to be set so as to abort in case of failure,
        -- because the cluster is left in an invalid state in that case.
        --
        -- The proper solution (in 2.9+) would be not to use tags for storing
        -- autorepair data, or make the TAGS_SET opcode not grab an instance's
        -- locks (if that's deemed safe). In the meantime, we introduce an
        -- artificial delay in the repair job (via a TestDelay opcode) so that
        -- once we have the job ID, the TAGS_SET job can complete before the
        -- repair job actually grabs the locks. (Please note that this is not
        -- about synchronization, but merely about speeding up the execution of
        -- the harep tool. If this TestDelay opcode is removed, the program is
        -- still correct.)
        let opcodes' =
              if delay > 0 then
                OpTestDelay { opDelayDuration = delay
                            , opDelayOnMaster = True
                            , opDelayOnNodes = []
                            , opDelayOnNodeUuids = Nothing
                            , opDelayRepeat = fromJust $ mkNonNegative 0
                            , opDelayInterruptible = False
                            , opDelayNoLocks = False
                            } : opcodes
              else
                opcodes

        uuid <- newUUID
        time <- getClockTime
        jids <- submitJobs'
                  opts
                  [map (annotateOpCode (optReason opts) now) opcodes']
                  client

        case jids of
          Bad e    -> exitErr e
          Ok jids' ->
            let arState' = ArPendingRepair (
                  updateTag $ AutoRepairData rtype uuid time jids' Nothing "")
                instData' = instData { arState = arState'
                                     , tagsToRemove = delCurTag instData
                                     }
            in
             commitChange opts client instData'  -- Adds "pending" label.

    otherSt -> do
      putStrLn ("Not repairing " ++ iname ++ " because it's in state " ++
                show otherSt)
      return instData

-- | Main function.
main :: Options -> [String] -> IO ()
main opts args = do
  unless (null args) $
    exitErr "this program doesn't take any arguments."

  luxiDef <- Path.defaultQuerySocket
  let master = fromMaybe luxiDef $ optLuxi opts
      opts' = opts { optLuxi = Just master }

  (ClusterData _ nl il _ _) <- loadExternalData opts'

  let iniDataRes = mapM setInitialState $ Container.elems il
  iniData <- exitIfBad "when parsing auto-repair tags" iniDataRes

  -- First step: check all pending repairs, see if they are completed.
  iniData' <- bracket (L.getLuxiClient master) L.closeClient $
              forM iniData . processPending opts

  -- Second step: detect any problems.
  let repairs = map (detectBroken nl . arInstance) iniData'

  -- Third step: create repair jobs for broken instances that are in ArHealthy.
  let maybeRepair c (i, r) = maybe (return i) (repairHealthy c i) r
      jobDelay = optJobDelay opts
      repairHealthy c i = case arState i of
                            ArHealthy _ -> doRepair opts c jobDelay i
                            _           -> const (return i)

  repairDone <- bracket (L.getLuxiClient master) L.closeClient $
                forM (zip iniData' repairs) . maybeRepair

  -- Print some stats and exit.
  let states = map ((, 1 :: Int) . arStateName . arState) repairDone
      counts = Map.fromListWith (+) states

  putStrLn "---------------------"
  putStrLn "Instance status count"
  putStrLn "---------------------"
  putStr . unlines . Map.elems $
    Map.mapWithKey (\k v -> k ++ ": " ++ show v) counts
