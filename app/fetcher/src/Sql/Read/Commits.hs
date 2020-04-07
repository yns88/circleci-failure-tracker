{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}

module Sql.Read.Commits where

import           Control.Monad.IO.Class             (liftIO)
import           Control.Monad.Trans.Except         (ExceptT (ExceptT),except, runExceptT)
import           Control.Monad.Trans.Reader         (ask)
import           Data.Aeson
import           Data.Either.Utils                  (maybeToEither)
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import           Database.PostgreSQL.Simple
import           GHC.Generics
import           GHC.Int                            (Int64)
import qualified Safe
import           Data.Set                             (Set)
import qualified Data.Set                             as Set

import qualified Pagination
import qualified DbHelpers
import qualified Commits
import qualified JsonUtils
import qualified BuildResults
import qualified Sql.QueryUtils                     as Q
import           Sql.Read.Types                     (DbIO, runQuery)
import qualified Builds


getNextMasterCommit ::
     Connection
  -> Builds.RawCommit
  -> IO (Either Text Builds.RawCommit)
getNextMasterCommit conn (Builds.RawCommit current_git_revision) = do
  rows <- query conn sql $ Only current_git_revision

  let mapped_rows = map (\(Only x) -> Builds.RawCommit x) rows
  return $ maybeToEither ("There are no commits that come after " <> current_git_revision) $ Safe.headMay mapped_rows
  where
    sql = Q.join [
        "SELECT sha1 FROM ordered_master_commits"
      , "WHERE"
      , "id > " <> Q.parens subquery
      , "ORDER BY id ASC"
      , "LIMIT 1"
      ]

    subquery = Q.join [
        "SELECT id"
      , "FROM ordered_master_commits"
      , "WHERE sha1 = ?"
      ]




data DownstreamCommitInfo = DownstreamCommitInfo {
    _sha1      :: Builds.RawCommit
  , _distance  :: Int
  , _pr_number :: Maybe Int
  } deriving (Generic, FromRow)

instance ToJSON DownstreamCommitInfo where
  toJSON = genericToJSON JsonUtils.dropUnderscore


apiMasterDownstreamCommits ::
     Builds.RawCommit
  -> DbIO [DownstreamCommitInfo]
apiMasterDownstreamCommits (Builds.RawCommit sha1) = do
  conn <- ask
  liftIO $ query conn sql $ Only sha1
  where
  sql = Q.join [
      "SELECT"
    , Q.list [
        "branch_commit"
      , "distance"
      , "pr_number"
      ]
    , "FROM pr_merge_bases"
    , "WHERE master_commit = ?"
    , "ORDER BY pr_number IS NULL"
    ]



getLatestKnownMasterCommit :: Connection -> IO (Maybe Text)
getLatestKnownMasterCommit conn = do
  rows <- query_ conn sql
  return $ Safe.headMay $ map (\(Only x) -> x) rows
  where
    sql = Q.join [
        "SELECT sha1 FROM ordered_master_commits"
      , "ORDER BY id DESC"
      , "LIMIT 1"
      ]


isMasterCommit :: Builds.RawCommit -> DbIO Bool
isMasterCommit (Builds.RawCommit sha1) = do
  conn <- ask
  liftIO $ do
    [Only exists] <- query conn master_commit_retrieval_sql $ Only sha1
    return exists
  where
    master_commit_retrieval_sql = Q.join [
        "SELECT EXISTS"
      , Q.parens "SELECT * FROM ordered_master_commits WHERE sha1 = ?"
      ]


getAllMasterCommits :: Connection -> IO (Set Builds.RawCommit)
getAllMasterCommits conn = do
  master_commit_rows <- query_ conn master_commit_retrieval_sql
  return $ Set.fromList $ map (\(Only x) -> x) master_commit_rows
  where
    master_commit_retrieval_sql = "SELECT sha1 FROM ordered_master_commits"


getMasterCommitIndex ::
     Connection
  -> Builds.RawCommit
  -> IO (Either Text Int64)
getMasterCommitIndex conn (Builds.RawCommit sha1) = do
  rows <- query conn sql $ Only sha1
  return $ maybeToEither ("Commit " <> sha1 <>" not found in master branch") $
    Safe.headMay $ map (\(Only x) -> x) rows
  where
    sql = "SELECT id FROM ordered_master_commits WHERE sha1 = ?"


-- | Returns results in descending order of commit ID
getMasterCommits ::
     Pagination.ParentOffsetMode
  -> DbIO (Either Text (DbHelpers.InclusiveNumericBounds Int64, [BuildResults.IndexedRichCommit]))
getMasterCommits parent_offset_mode = do
  conn <- ask
  liftIO $ case parent_offset_mode of
    Pagination.CommitIndices bounds@(DbHelpers.InclusiveNumericBounds minbound maxbound) -> do

      rows <- liftIO $ query conn sql_commit_id_bounds (minbound, maxbound)
      let mapped_rows = map f rows
      return $ pure (bounds, mapped_rows)

    Pagination.FixedAndOffset (Pagination.OffsetLimit offset_mode commit_count) -> runExceptT $ do
      latest_id <- ExceptT $ case offset_mode of

        Pagination.Count offset_count -> do
          xs <- query conn sql_first_commit_id $ Only offset_count
          return $ maybeToEither "No master commits!" $ Safe.headMay $ map (\(Only x) -> x) xs

        Pagination.Commit (Builds.RawCommit sha1) -> do
          xs <- query conn sql_associated_commit_id $ Only sha1
          return $ maybeToEither (T.unwords ["No commit with sha1", sha1]) $
            Safe.headMay $ map (\(Only x) -> x) xs

      rows <- liftIO $ query conn sql_commit_id_and_offset (latest_id :: Int64, commit_count)

      let mapped_rows = map f rows
          maybe_first_commit_index = DbHelpers.db_id <$> Safe.lastMay mapped_rows

      first_commit_index <- except $ maybeToEither "No commits found!" maybe_first_commit_index

      return (DbHelpers.InclusiveNumericBounds first_commit_index latest_id, mapped_rows)

  where
    f ( commit_id
      , commit_sha1
      , commit_number
      , maybe_pr_number
      , maybe_message
      , maybe_tree_sha1
      , maybe_author_name
      , maybe_author_email
      , maybe_author_date
      , maybe_committer_name
      , maybe_committer_email
      , maybe_committer_date
      , was_built
      , populated_config_yaml
      , downstream_commit_count
      , reverted_sha1
      , total_required_commit_job_count
      , failed_or_incomplete_required_job_count
      , failed_required_job_count
      , disqualifying_jobs_array) =
      DbHelpers.WithId commit_id $ BuildResults.CommitAndMetadata
        wrapped_sha1
        maybe_metadata
        commit_number
        maybe_pr_number
        was_built
        populated_config_yaml
        downstream_commit_count
        reverted_sha1
        maybe_required_job_counts

      where
        maybe_required_job_counts = BuildResults.RequiredJobCounts <$>
          total_required_commit_job_count <*>
          failed_or_incomplete_required_job_count <*>
          failed_required_job_count <*>
          disqualifying_jobs_array

        wrapped_sha1 = Builds.RawCommit commit_sha1
        maybe_metadata = Commits.CommitMetadata wrapped_sha1 <$>
          maybe_message <*>
          maybe_tree_sha1 <*>
          maybe_author_name <*>
          maybe_author_email <*>
          maybe_author_date <*>
          maybe_committer_name <*>
          maybe_committer_email <*>
          maybe_committer_date

    sql_first_commit_id = Q.join [
        "SELECT id"
      , "FROM ordered_master_commits"
      , "ORDER BY id DESC"
      , "LIMIT 1"
      , "OFFSET ?;"
      ]

    sql_associated_commit_id = Q.join [
        "SELECT id"
      , "FROM ordered_master_commits"
      , "WHERE sha1 = ?;"
      ]

    commits_query_prefix = Q.join [
        "SELECT"
      , Q.list [
            "id"
          , "sha1"
          , "commit_number"
          , "github_pr_number"
          , "message"
          , "tree_sha1"
          , "author_name"
          , "author_email"
          , "author_date"
          , "committer_name"
          , "committer_email"
          , "committer_date"
          , "was_built"
          , "populated_config_yaml"
          , "downstream_commit_count"
          , "reverted_sha1"
          , "total_required_commit_job_count"
          , "not_succeeded_required_job_count"
          , "failed_required_job_count"
          , "disqualifying_jobs_array"
          ]
      , "FROM master_ordered_commits_with_metadata_mview"
      ]

    sql_commit_id_and_offset = Q.join [
        commits_query_prefix
      , "WHERE id <= ?"
      , "ORDER BY id DESC"
      , "LIMIT ?"
      ]

    sql_commit_id_bounds = Q.join [
        commits_query_prefix
      , "WHERE"
      , Q.conjunction [
          "id >= ?"
        , "id <= ?"
        ]
      , "ORDER BY id DESC"
      ]


apiBrokenCommitsWithoutMetadata :: DbIO [Builds.RawCommit]
apiBrokenCommitsWithoutMetadata = runQuery
  "SELECT vcs_revision FROM broken_commits_without_metadata"


getLatestMasterCommitWithMetadata :: DbIO (Either Text Builds.RawCommit)
getLatestMasterCommitWithMetadata = do
  conn <- ask
  liftIO $ do
    rows <- query_ conn sql
    return $ maybeToEither "No commit has metdata" $ Safe.headMay $ map (\(Only x) -> Builds.RawCommit x) rows
  where
    sql = Q.join [
        "SELECT ordered_master_commits.sha1"
      , "FROM ordered_master_commits"
      , "LEFT JOIN commit_metadata"
      , "ON ordered_master_commits.sha1 = commit_metadata.sha1"
      , "WHERE commit_metadata.sha1 IS NOT NULL"
      , "ORDER BY ordered_master_commits.id DESC"
      , "LIMIT 1"
      ]

