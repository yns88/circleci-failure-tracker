{-# LANGUAGE DeriveGeneric #-}

module MergeBase where

import           Control.Monad              (void)
import           Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import           Data.Bifunctor             (first)
import           Data.Either                (partitionEithers)
import           Data.String.Utils          (strip)
import qualified Data.Text                  as T
import qualified Development.Shake.Command  as Command
import           System.Exit                (ExitCode (ExitFailure, ExitSuccess))
import           Text.Read                  (readEither)

import qualified Builds


data CommitMergeBase = CommitMergeBase {
    branch_commit :: Builds.RawCommit
  , master_commit :: Builds.RawCommit -- ^ merge base
  , distance      :: Int
  }


-- | Distance of commit from master
gitCommitDistance ::
     FilePath
  -> Builds.RawCommit
  -> Builds.RawCommit
  -> IO (Either T.Text Int)
gitCommitDistance
    git_dir
    (Builds.RawCommit merge_base_sha1)
    (Builds.RawCommit branch_commit_sha1) = do

  (Command.Exit exit_status, Command.Stdout out, Command.Stderr err) <- Command.cmd $ unwords [
      "git"
    , "--git-dir"
    , git_dir
    , "rev-list"
    , "--ancestry-path"
    , "--count"
    , T.unpack merge_base_sha1 <> ".." <> T.unpack branch_commit_sha1
    ]

  let either_count_string = exitStatusToEither exit_status out err
  return $ first T.pack $ readEither =<< either_count_string


-- | Computes the merge base of the provided commit and the
-- master branch using the local git repository
gitMergeBase ::
     FilePath -- ^ repo git dir
  -> Builds.RawCommit
  -> IO (Either T.Text Builds.RawCommit)
gitMergeBase git_dir (Builds.RawCommit commit_sha1) = do
  (Command.Exit exit_status, Command.Stdout out, Command.Stderr err) <- Command.cmd $ unwords [
      "git"
    , "--git-dir"
    , git_dir
    , "merge-base"
    , "origin/master"
    , T.unpack commit_sha1
    ]

  return $ first T.pack $ Builds.RawCommit . T.pack <$> exitStatusToEither exit_status out err


computeMergeBaseAndDistance ::
     FilePath -- ^ repo git dir
  -> Builds.RawCommit
  -> IO (Either (Builds.RawCommit, T.Text) CommitMergeBase)
computeMergeBaseAndDistance git_dir commit_sha1 = do
  result <- runExceptT $ do

    merge_base <- ExceptT $ gitMergeBase git_dir commit_sha1
    distance <- ExceptT $ gitCommitDistance git_dir merge_base commit_sha1
    return $ CommitMergeBase commit_sha1 merge_base distance

  return $ first (\x -> (commit_sha1, x)) result


exitStatusToEither exit_status out err =
  case exit_status of
    ExitSuccess       -> Right $ strip out
    ExitFailure _code -> Left $ strip err


fetchRefs :: FilePath -> IO (Either T.Text ())
fetchRefs git_dir = do
  (Command.Exit exit_status, Command.Stdout out, Command.Stderr err) <- Command.cmd $ unwords [
      "git"
    , "--git-dir"
    , git_dir
    , "fetch"
    , "origin"
    ]

  return $ first T.pack $ void $ exitStatusToEither exit_status out err


computeMergeBasesLocally ::
     FilePath -- ^ repo git dir
  -> [Builds.RawCommit]
  -> IO ([Builds.RawCommit], [CommitMergeBase])
computeMergeBasesLocally git_dir non_master_uncached_failed_commits = do

  fetchRefs git_dir

  let f = computeMergeBaseAndDistance git_dir

  merge_base_eithers <- mapM f non_master_uncached_failed_commits
  let (uncomputed_commits, computed_merge_bases) = partitionEithers merge_base_eithers
{-
  putStrLn $ unwords [
      "MB result:"
    , show mb_result
    ]
-}
  return (map fst uncomputed_commits, computed_merge_bases)