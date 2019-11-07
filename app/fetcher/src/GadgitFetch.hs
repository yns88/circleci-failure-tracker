{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module GadgitFetch where

import           Control.Monad.IO.Class     (liftIO)
import           Control.Monad.Trans.Except (ExceptT (ExceptT), except,
                                             runExceptT)
import           Data.Aeson                 (FromJSON, eitherDecode,
                                             genericParseJSON, parseJSON,
                                             toJSON)
import           Data.Either.Utils          (maybeToEither)
import qualified Data.Maybe                 as Maybe
import qualified Data.Text                  as T
import           GHC.Generics
import qualified Network.HTTP.Client        as NC
import           Network.Wreq               as NW

import qualified Builds
import qualified FetchHelpers
import qualified JsonUtils


-- | Note: "result" and "error" are mutually exclusive
data GadgitResponse a = GadgitResponse {
    _result  :: Maybe a
  , _success :: Bool
  , _error   :: Maybe String
  } deriving Generic

instance (FromJSON a) => FromJSON (GadgitResponse a) where
  parseJSON = genericParseJSON JsonUtils.dropUnderscore


data PullRequestHeadAssociation = PullRequestHeadAssociation {
    _head_commit :: Builds.RawCommit
  , _pr_number   :: Builds.PullRequestNumber
  } deriving (Show, Generic)

instance FromJSON PullRequestHeadAssociation where
  parseJSON = genericParseJSON JsonUtils.dropUnderscore


-- | TODO: Handle errors on individual items
getPullRequestHeadCommitsBulk ::
     [Builds.PullRequestNumber]
  -> IO (Either String [PullRequestHeadAssociation])
getPullRequestHeadCommitsBulk pr_numbers = runExceptT $ do
  response <- ExceptT $ liftIO $ FetchHelpers.safeGetUrl $
    NW.post url_string $ toJSON pr_numbers

  decoded_json <- except $ eitherDecode $ NC.responseBody response
  except $ if _success decoded_json
    then maybeToEither "API indicates success but has no result!" $ _result decoded_json
    else Left $ unwords [
        "Webservice error:"
      , Maybe.fromMaybe "<none>" $ _error decoded_json
      ]

  where
    url_string = "http://gadgit.pytorch.org/bulk-pull-request-heads"


getSinglePullRequestHeadCommit ::
     Builds.PullRequestNumber
  -> IO (Either String Builds.RawCommit)
getSinglePullRequestHeadCommit (Builds.PullRequestNumber pr_num) = runExceptT $ do

  response <- ExceptT $ liftIO $ FetchHelpers.safeGetUrl $ NW.get url_string
  decoded_json <- except $ eitherDecode $ NC.responseBody response
  except $ if _success decoded_json
    then maybeToEither "API indicates success but has no result!" $ Builds.RawCommit <$> _result decoded_json
    else Left $ unwords [
        "Webservice error:"
      , Maybe.fromMaybe "<none>" $ _error decoded_json
      ]

  where
    url_string = "http://gadgit.pytorch.org/pr-head-commit/" <> show pr_num


getContainingPRs :: Builds.RawCommit -> IO (Either String [Builds.PullRequestNumber])
getContainingPRs (Builds.RawCommit sha1) = runExceptT $ do

  response <- ExceptT $ liftIO $ FetchHelpers.safeGetUrl $ NW.get url_string
  decoded_json <- except $ eitherDecode $ NC.responseBody response
  except $ if _success decoded_json
    then maybeToEither "API indicates success but has no result!" $ map Builds.PullRequestNumber <$> _result decoded_json
    else Left $ unwords [
        "Webservice error:"
      , Maybe.fromMaybe "<none>" $ _error decoded_json
      ]

  where
    url_string = "http://gadgit.pytorch.org/head-of-pull-requests/" <> T.unpack sha1
