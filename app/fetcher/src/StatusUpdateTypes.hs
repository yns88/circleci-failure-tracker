{-# LANGUAGE OverloadedStrings #-}

module StatusUpdateTypes where

import           Data.List            (partition)
import           Data.List.NonEmpty   (NonEmpty)
import           Data.Text            (Text)
import qualified Data.Text.Lazy       as LT
import qualified Data.Tree            as Tr

import qualified Builds
import qualified CommitBuilds
import qualified DbHelpers
import qualified GithubChecksApiFetch
import qualified Sql.Read.Types       as SqlReadTypes
import qualified Sql.Update           as SqlUpdate
import qualified StatusEventQuery
import qualified UnmatchedBuilds


gitHubStatusFailureString :: LT.Text
gitHubStatusFailureString = "failure"

gitHubStatusSuccessString :: LT.Text
gitHubStatusSuccessString = "success"


class Partition a where
  count :: a -> Int


instance Partition [a] where
  count = length


-- TODO use this
class ToTree a where
  toTree :: a -> Tr.Tree a


data NonCircleCIItems = NewNonCircleCIItems {
    failed_statuses_with_providers              :: [(DbHelpers.WithId SqlReadTypes.CiProviderHostname, NonEmpty StatusEventQuery.GitHubStatusEventGetter)]
  , failed_check_run_entries_excluding_facebook :: [GithubChecksApiFetch.GitHubCheckRunsEntry]
  }


hasAnyNonCircleCIFailures :: NonCircleCIItems -> Bool
hasAnyNonCircleCIFailures (NewNonCircleCIItems failed_statuses_with_ci_providers failed_check_run_entries_excluding_facebook) =
  not (null failed_statuses_with_ci_providers) || not (null failed_check_run_entries_excluding_facebook)


data GitHubJobStatuses = NewGitHubJobStatuses {
    scannable_statuses        :: [Builds.UniversalBuildId]
  , circleci_failed_job_count :: Int
  , non_circleci_items        :: NonCircleCIItems
  }


hasAnyFailures :: GitHubJobStatuses -> Bool
hasAnyFailures (NewGitHubJobStatuses _ circleci_failed_count non_circleci_items) =
  circleci_failed_count > 0 || hasAnyNonCircleCIFailures non_circleci_items


data CommitPageInfo = NewCommitPageInfo {
    toplevel_partitioning :: UpstreamnessBuildsPartition SqlReadTypes.StandardCommitBuildWrapper
  , raw_github_statuses :: GitHubJobStatuses
  }


data UpstreamnessBuildsPartition a = NewUpstreamnessBuildsPartition {
    my_upstream_builds    :: [(a, SqlReadTypes.UpstreamBrokenJob)]
  , my_nonupstream_builds :: NonUpstreamBuildPartition a
  }


data SpecialCasedBuilds a = NewSpecialCasedBuilds {
    xla_build_failures :: [a]
  }


data NonUpstreamBuildPartition a = NewNonUpstreamBuildPartition {
    pattern_matched_builds             :: FlakyBuildPartition (SqlReadTypes.ParameterizedWrapperTuple a)
  , unmatched_builds                   :: [UnmatchedBuilds.UnmatchedBuild]
  , special_cased_nonupstream_failures :: SpecialCasedBuilds a
  , timed_out_builds :: [UnmatchedBuilds.UnmatchedBuild]
  }


data FlakyBuildPartition a = NewFlakyBuildPartition {
    tentatively_flaky_builds :: TentativeFlakyBuilds a
  , nonflaky_builds          :: NonFlakyBuilds a
  , confirmed_flaky_builds   :: [SqlReadTypes.StandardCommitBuildWrapper]
  } deriving Show


data TentativeFlakyBuilds a = NewTentativeFlakyBuilds {
    tentative_flaky_triggered_reruns   :: [a]
  , tentative_flaky_untriggered_reruns :: [a]
  } deriving Show


data NonFlakyBuilds a = NewNonFlakyBuilds {
    nonflaky_by_pattern                :: [a]
  , nonflaky_by_empirical_confirmation :: [a]
  } deriving Show


instance Partition (TentativeFlakyBuilds a) where
  count x = sum $ map (\f -> length $ f x) field_extractors
    where
      field_extractors = [
          tentative_flaky_triggered_reruns
        , tentative_flaky_untriggered_reruns
        ]


instance Partition (NonFlakyBuilds a) where
  count x = sum $ map (\f -> length $ f x) field_extractors
    where
      field_extractors = [
          nonflaky_by_pattern
        , nonflaky_by_empirical_confirmation
        ]


partitionMatchedBuilds ::
     [SqlReadTypes.StandardCommitBuildWrapper]
  -> [SqlReadTypes.CommitBuildWrapperTuple]
  -> FlakyBuildPartition SqlReadTypes.CommitBuildWrapperTuple
partitionMatchedBuilds
    confirmed_flaky_breakages
    pattern_matched_builds =

  NewFlakyBuildPartition
    tentative_flaky_builds_partition
    nonflaky_builds_partition
    confirmed_flaky_breakages

  where
    tentative_flaky_builds_partition = NewTentativeFlakyBuilds rerun_was_triggered_breakages rerun_not_triggered_breakages

    nonflaky_builds_partition = NewNonFlakyBuilds nonupstream_nonflaky_breakages negatively_confirmed_flaky_breakages


    -- Best pattern match is clasified as flaky
    tentative_flakiness_predicate = CommitBuilds._is_flaky . CommitBuilds._failure_mode . CommitBuilds._commit_build . fst


    (nonupstream_tentatively_flaky_breakages, nonupstream_nonflaky_breakages) =
      partition tentative_flakiness_predicate pattern_matched_builds


    has_completed_rerun_predicate = SqlReadTypes.has_completed_rerun . CommitBuilds._supplemental . fst

    (completed_rerun_flaky_breakages, not_completed_rerun_flaky_breakages) =
      partition has_completed_rerun_predicate nonupstream_tentatively_flaky_breakages


    has_triggered_rerun_predicate = SqlReadTypes.has_triggered_rebuild . CommitBuilds._supplemental . fst

    (rerun_was_triggered_breakages, rerun_not_triggered_breakages) =
      partition has_triggered_rerun_predicate not_completed_rerun_flaky_breakages

    negatively_confirmed_flaky_breakages = completed_rerun_flaky_breakages


data BuildSummaryStats = NewBuildSummaryStats {
    _upstream_breakages_info    :: SqlUpdate.UpstreamBreakagesInfo
  , total_circleci_fail_joblist :: [Text]
  }
