{-# LANGUAGE OverloadedStrings #-}

-- | Common operations and data types in simulations.
module Network.Wire.Simulations
    ( -- * Conversation Setup
      prepareConv

      -- * Messages
    , BotMessage (..)
    , mkAssetMsg
    , mkTextMsg
    , AssetInfo
    , assetInfoKey
    , assetInfoToken
    , assetInfoKeys

      -- * Assertions
    , requireAssetMsg
    , requireTextMsg
    , assertNoClientMismatch
    , assertClientMissing

      -- * Re-exports
    , encode
    , decode
    ) where

import Control.Lens ((^.))
import Control.Monad
import Control.Monad.Catch
import Data.ByteString (ByteString)
import Data.ByteString.Conversion
import Data.Id (ConvId, UserId)
import Data.List1 (list1)
import Data.Maybe (fromMaybe)
import Data.Monoid
import Data.Serialize
import Data.Text (Text)
import Network.Wire.Bot
import Network.Wire.Bot.Assert
import Network.Wire.Bot.Crypto
import Network.Wire.Client.API.Asset
import Network.Wire.Client.API.Conversation
import Network.Wire.Client.API.User hiding (Asset (..))

import qualified Data.ByteString    as BS
import qualified Data.Map.Strict    as Map
import qualified Data.Set           as Set
import qualified Data.Text          as Text
import qualified Data.Text.Encoding as Text

--------------------------------------------------------------------------------
-- Conversation Setup

-- | Set up a conversation between a given list of bots, thereby ensuring that
-- all of them are connected.
prepareConv :: [Bot] -> BotNet ConvId
prepareConv g
    | length g <= 1 = error "prepareConv: At least two bots required"
    | length g == 2 = do
        let [a, b] = g
        connectIfNeeded g
        conv <- (>>= ucConvId) <$> runBotSession a (getConnection (botId b))
        requireMaybe conv $
            "Missing 1-1 conversation between: " <>
                Text.concat (Text.pack . show . botId <$> [a, b])
    | otherwise = do
        let (a : b : c : cs) = g
        connectIfNeeded g
        let cIds = botId <$> list1 c cs
        conv <- cnvId <$> runBotSession a (createConv (botId b) cIds Nothing)
        assertConvCreated conv a (b:c:cs)
        return conv

connectIfNeeded :: [Bot] -> BotNet ()
connectIfNeeded g = mapM_ (uncurry (go 6)) [(a, b) | a <- g, b <- g, botId a /= botId b]
  where
    go :: Int -> Bot -> Bot -> BotNet ()
    go 0 _ _ = return ()
    go n a b = do
        connected <- runBotSession a $ do
            s <- fmap ucStatus <$> getConnection (botId b)
            case s of
                Nothing -> do
                    void $ connectTo (ConnectionRequest (botId b) (fromMaybe "" (botEmail a)) (Message "Hi there!"))
                    assertConnectRequested a b
                    return False
                Just Pending -> do
                    void $ updateConnection (botId b) (ConnectionUpdate Accepted)
                    assertConnectAccepted a b
                    return True
                Just Sent -> return False
                _         -> return True
        unless connected (go (n - 1) b a)

--------------------------------------------------------------------------------
-- Messages

data BotMessage
    = BotAssetMessage AssetInfo
    | BotTextMessage Text
    deriving (Eq, Show)

instance Serialize BotMessage where
    put (BotTextMessage  m) = putWord8 1 >> putByteString (Text.encodeUtf8 m)
    put (BotAssetMessage i) = putWord8 2 >> put i

    get = do
        t <- getWord8
        case t of
            1 -> do
                bs <- remaining >>= getByteString
                either (fail . show)
                       (return . BotTextMessage)
                       (Text.decodeUtf8' bs)
            2 -> BotAssetMessage <$> get
            _ -> fail $ "Unexpected message type: " ++ show t

data AssetInfo = AssetInfo
    { assetInfoKey   :: !AssetKey
    , assetInfoToken :: !(Maybe AssetToken)
    , assetInfoKeys  :: !SymmetricKeys
    } deriving (Eq, Show)

instance Serialize AssetInfo where
    put (AssetInfo key tok keys) = do
        let k = toByteString' key
        putWord16be (fromIntegral (BS.length k))
        putByteString k
        let t = maybe "" toByteString' tok
        putWord16be (fromIntegral (BS.length t))
        putByteString t
        put keys

    get = do
        klen <- getWord16be
        kbs  <- getByteString (fromIntegral klen)
        k    <- maybe (fail "Invalid asset key")
                      return
                      (fromByteString kbs)
        tlen <- getWord16be
        t    <- if tlen == 0 then return Nothing else do
                    tbs  <- getByteString (fromIntegral tlen)
                    maybe (fail "Invalid asset token")
                          (return . Just)
                          (fromByteString tbs)
        AssetInfo k t <$> get

mkAssetMsg :: Asset -> SymmetricKeys -> BotMessage
mkAssetMsg a = BotAssetMessage . AssetInfo (a^.assetKey) (a^.assetToken)

mkTextMsg :: Text -> BotMessage
mkTextMsg = BotTextMessage

--------------------------------------------------------------------------------
-- Assertions

requireAssetMsg :: MonadThrow m => ByteString -> m AssetInfo
requireAssetMsg bs = do
    m <- requireMessage bs
    case m of
        BotAssetMessage info -> return info
        x                    -> throwM $ RequirementFailed ("Unexpected message: " <> Text.pack (show x))

requireTextMsg :: MonadThrow m => ByteString -> m Text
requireTextMsg bs = do
    m <- requireMessage bs
    case m of
        BotTextMessage t -> return t
        x                -> throwM $ RequirementFailed ("Unexpected message: " <> Text.pack (show x))

requireMessage :: MonadThrow m => ByteString -> m BotMessage
requireMessage = requireRight . decode

assertNoClientMismatch :: ClientMismatch -> BotSession ()
assertNoClientMismatch cm = do
    assertEqual (UserClients Map.empty) (missingClients   cm) "Missing Clients"
    assertEqual (UserClients Map.empty) (redundantClients cm) "Redundant Clients"
    assertEqual (UserClients Map.empty) (deletedClients   cm) "Deleted Clients"

assertClientMissing :: UserId -> BotClient -> ClientMismatch -> BotSession ()
assertClientMissing u d cm =
    assertEqual (UserClients (Map.singleton u (Set.singleton $ botClientId d)))
                (missingClients cm)
                "Missing Clients"

