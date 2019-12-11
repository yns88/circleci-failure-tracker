{-# LANGUAGE OverloadedStrings #-}

module CommentRender where

import           Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import           Data.Text          (Text)
import qualified Data.Text          as T
import qualified Data.Text.Lazy     as LT
import qualified Data.Tree          as Tr

import qualified Builds
import qualified CommitBuilds
import qualified Constants
import qualified DbHelpers
import qualified GadgitFetch
import qualified Markdown           as M
import qualified MatchOccurrences
import qualified MyUtils
import qualified SqlRead
import qualified SqlUpdate
import qualified StatusUpdateTypes
import qualified WebApi


viableBranchName = "viable/strict"


webserverBaseUrl :: LT.Text
webserverBaseUrl = "https://dr.pytorch.org"


viableCommitsHistoryUrl = webserverBaseUrl <> "/master-viable-commits.html"


circleCISmallAvatarUrl :: Text
circleCISmallAvatarUrl = "https://avatars0.githubusercontent.com/ml/7?s=12"


drCIApplicationTitle :: Text
drCIApplicationTitle = "Dr. CI"


drCIPullRequestCommentsReadmeUrl :: Text
drCIPullRequestCommentsReadmeUrl = "https://github.com/kostmo/circleci-failure-tracker/tree/master/docs/from-pull-request-comment"


circleCIBuildUrlPrefix = "https://circleci.com/gh/pytorch/pytorch/"


genUnmatchedBuildsTable unmatched_builds =
  M.table header_columns data_rows
  where
    header_columns = ["Job", "Step"]
    data_rows = map gen_unmatched_build_row unmatched_builds

    gen_unmatched_build_row (WebApi.UnmatchedBuild _build step_name _ job_name _ _ _ _) = [
        T.unwords [
            M.image "CircleCI" circleCISmallAvatarUrl
          , M.sup job_name
          ]
      , M.sup step_name
      ]


genBuildFailuresTable ::
     StatusUpdateTypes.CommitPageInfo
  -> [Text]
genBuildFailuresTable (StatusUpdateTypes.CommitPageInfo revision_builds unmatched_builds) =
  pattern_matched_section <> pattern_unmatched_section
  where
    pattern_matched_header = M.heading 3 $ M.colonize [
        MyUtils.pluralize (length revision_builds) "failure"
      , "recognized by patterns"
      ]

    matched_builds_details_block = concat $ zipWith gen_matched_build_section [1..] revision_builds
    pattern_matched_section = if null revision_builds
      then mempty
      else pure pattern_matched_header
        <> matched_builds_details_block

    pattern_unmatched_header = M.heading 3 $ M.colonize [
        MyUtils.pluralize (length unmatched_builds) "failure"
      , M.italic "not"
      , "recognized by patterns"
      ]

    pattern_unmatched_section = if null unmatched_builds
      then mempty
      else pure pattern_unmatched_header
        <> NE.toList (genUnmatchedBuildsTable unmatched_builds)

    gen_matched_build_section idx (CommitBuilds.NewCommitBuild (Builds.StorableBuild (DbHelpers.WithId ubuild_id universal_build) build_obj) match_obj _ _) = [
        M.heading 4 $ T.unwords [
            circleci_image_link
          , Builds.job_name build_obj
          , M.parens $ T.pack $ MyUtils.renderFrac idx $ length revision_builds
          ]
      , T.unwords [
          M.bold "Step:"
        , MatchOccurrences._build_step match_obj
        , M.parens $ M.link "details" $ LT.toStrict webserverBaseUrl <> "/build-details.html?build_id=" <> T.pack (show ubuild_id)
        ]
      ] <> code_block_lines
      where
        code_block_lines = NE.toList $ M.codeBlock $ pure $ MatchOccurrences._line_text match_obj

        (Builds.NewBuildNumber provider_build_number) = Builds.provider_buildnum universal_build
        circleci_icon = M.image "See CircleCI build" circleCISmallAvatarUrl
        circleci_image_link = M.link circleci_icon $
          circleCIBuildUrlPrefix <> T.pack (show provider_build_number)


generateCommentMarkdown ::
     Maybe SqlRead.PostedPRComment
  -> StatusUpdateTypes.BuildSummaryStats
  -> GadgitFetch.AncestryPropositionResponse
  -> StatusUpdateTypes.CommitPageInfo
  -> Builds.RawCommit
  -> Text
generateCommentMarkdown
    maybe_previous_pr_comment
    build_summary_stats
    ancestry_result
    commit_page_info
    (Builds.RawCommit sha1_text) =
  M.paragraphs $ preliminary_lines_list ++ optional_suffix
  where
    build_failures_table_lines = genBuildFailuresTable commit_page_info

    detailed_build_issues_section = if null build_failures_table_lines
      then []
      else [
          M.heading 2 "Detailed failure analysis (WIP)"
        , M.colonize [
            "Here are the"
          , M.link "reasons each build failed" dr_ci_commit_details_link
          ]
        , T.unlines build_failures_table_lines
        ]

    footer_section1 = T.unlines [
        "---"
      , M.sentence [
          "This comment was automatically generated by"
        , M.link drCIApplicationTitle drCIPullRequestCommentsReadmeUrl
        ]
      , M.sentence [
          "Follow"
        , M.link "this link to opt-out" opt_out_url
        , "of these comments for your Pull Requests"
        ]
      ]

    footer_section2 = M.sentence [
        "Please report bugs/suggestions on the"
      , M.link "GitHub issue tracker" "https://github.com/kostmo/circleci-failure-tracker/issues"
      ]

    preliminary_lines_list = [
        T.unlines [
          M.heading 2 "CircleCI build failures summary"
        , M.colonize [
            "As of commit"
          , T.take Constants.gitCommitPrefixLength sha1_text
          ]
        , M.bulletTree $ genMetricsTreeVerbose ancestry_result build_summary_stats
        ]
      ] ++ detailed_build_issues_section ++ [footer_section1, footer_section2]


    -- Note that using the current count of N comments as the revision count will be
    -- appropriate for the (N+1)th comment (the one that's about to be posted), because
    -- the first post doesn't count as a "revision".
    optional_suffix = case maybe_previous_pr_comment of
      Nothing -> []
      Just previous_pr_comment -> [
          M.italic $ M.sentence [
            "This comment has been revised"
          , MyUtils.pluralize (SqlRead._revision_count previous_pr_comment) "time"
          ]
        ]

    dr_ci_base_url = LT.toStrict webserverBaseUrl
    dr_ci_commit_details_link = dr_ci_base_url <> "/commit-details.html?sha1=" <> sha1_text
    opt_out_url = dr_ci_base_url <> "/admin/comments-opt-out.html"


genMetricsTreeVerbose ::
     GadgitFetch.AncestryPropositionResponse
  -> StatusUpdateTypes.BuildSummaryStats
  -> Tr.Forest (NonEmpty Text)
genMetricsTreeVerbose
    ancestry_response
    (StatusUpdateTypes.NewBuildSummaryStats flaky_count pre_broken_info all_failures) =
  optional_kb_metric <> failures_introduced_in_pull_request <> flaky_bullet_tree
  where

    (GadgitFetch.AncestryPropositionResponse (GadgitFetch.RefAncestryProposition _supposed_ancestor _supposed_descendant) ancestry_result) = ancestry_response

    Builds.RawCommit merge_base_sha1_text = SqlUpdate.merge_base pre_broken_info

    definite_older_commit_advice = pure $ M.colonize [
        M.commaize [
          "Since your merge base"
--        , M.codeInline supposed_ancestor
        , "is older than"
        , M.codeInline viableBranchName
        ]
      , "run these commands"
      ]

    possible_older_commit_advice = pure $ M.colonize [
        "If your commit is older than"
      , M.codeInline viableBranchName
      ]

    older_commit_codeblock = M.codeBlock $
      ("git fetch " <> viableBranchName) :| ["git rebase " <> viableBranchName]

    newer_commit_advice = pure $ M.colonize [
        M.commaize [
            "If your commit is newer than"
          , M.codeInline viableBranchName
          ]
      , "you can try basing on an older, stable commit"
      ]

    newer_commit_codeblock = M.codeBlock $
      ("git fetch " <> viableBranchName) :| ["git rebase --onto " <> viableBranchName <> " $(git merge-base origin/master HEAD)"]


    definite_older_rebase_advice_children = [
        definite_older_commit_advice <> older_commit_codeblock
      ]

    maybe_newer_rebase_advice_children = [
        possible_older_commit_advice <> older_commit_codeblock
      , newer_commit_advice <> newer_commit_codeblock
      ]

    rebase_advice_children = case ancestry_result of
      GadgitFetch.RefIsAncestor    -> definite_older_rebase_advice_children
      GadgitFetch.RefIsNotAncestor -> maybe_newer_rebase_advice_children

    rebase_advice_intro = pure $ M.colonize [
        "You may want to rebase on the"
      , M.codeInline viableBranchName
      , "branch"
      , M.parens $ T.unwords [
          "see its"
        , M.link "recency history" $ LT.toStrict viableCommitsHistoryUrl
        ]
      ]

    rebase_advice_section = Tr.Node rebase_advice_intro $ map pure rebase_advice_children

    upstream_breakage_bullet_children = [rebase_advice_section]

    pre_broken_list = SqlUpdate.inferred_upstream_caused_broken_jobs pre_broken_info
    upstream_broken_count = length pre_broken_list
    total_failcount = length all_failures
    broken_in_pr_count = total_failcount - upstream_broken_count

    bold_fraction a b = M.bold $ T.pack $ show a <> "/" <> show b

    grid_view_query_parms = [
        ("count", "10")
      , ("sha1", T.unpack merge_base_sha1_text)
      , ("should_suppress_scheduled_builds", "true")
      , ("should_suppress_fully_successful_columns", "true")
      , ("max_columns_suppress_successful", "35")
      ]

    grid_view_url = T.pack $ "https://dr.pytorch.org/master-timeline.html?" <> MyUtils.genUrlQueryString grid_view_query_parms

    upstream_breakage_bullet_tree = Tr.Node (
       pure $ T.unwords [
           bold_fraction upstream_broken_count total_failcount
         , "broken upstream at merge base"
         , T.take Constants.gitCommitPrefixLength merge_base_sha1_text
         , M.parens $ T.unwords [
             "see"
           , M.link "grid view" grid_view_url
           ]
         ]
       ) upstream_breakage_bullet_children

    optional_kb_metric = if null pre_broken_list
      then []
      else [upstream_breakage_bullet_tree]


    failures_introduced_in_pull_request = [
        pure $ pure $ T.unwords [
            bold_fraction broken_in_pr_count total_failcount
          , "failures introduced in this PR"
          ]
      ]

    flaky_bullet_tree = if flaky_count > 0
      then [
        Tr.Node (pure $ T.unwords [
            bold_fraction flaky_count total_failcount
          , "recognized as flaky"
          ]) [pure $ pure "Re-run these jobs?"]
        ]
      else []
