module Cardano.CEM.Monads.CLB where

import Prelude

import Control.Monad.Reader (MonadReader (..), ReaderT (..), asks)
import Control.Monad.State (StateT (..), gets)
import Control.Monad.Trans (MonadIO (..))
import Data.Map qualified as Map
import Data.Set qualified as Set

-- Cardano imports
import Cardano.Api hiding (queryUtxo)
import Cardano.Api.Query (fromLedgerUTxO)
import Cardano.Api.Shelley (LedgerProtocolParameters (..))

-- Lib imports
import Clb (
  ClbState (mockConfig),
  ClbT (..),
  MockConfig (..),
  SlotConfig (scSlotZeroTime),
  ValidationResult (..),
  getCurrentSlot,
  getEpochInfo,
  getUtxosAtState,
  initClb,
  intToCardanoSk,
  sendTx,
 )
import Clb.MockConfig (defaultBabbage)
import Clb.TimeSlot (posixTimeToUTCTime)

-- CEM imports

import Cardano.CEM.Monads
import Cardano.CEM.Monads.L1Commons
import Cardano.CEM.OffChain (fromPlutusAddressInMonad)
import Cardano.Extras

instance (MonadFail m) => MonadBlockchainParams (ClbT m) where
  askNetworkId :: ClbT m NetworkId
  askNetworkId = gets (mockConfigNetworkId . mockConfig)

  queryCurrentSlot :: ClbT m SlotNo
  queryCurrentSlot = getCurrentSlot

  queryBlockchainParams = do
    protocolParameters <- gets (mockConfigProtocol . mockConfig)
    slotConfig <- gets (mockConfigSlotConfig . mockConfig)
    eraHistory <- LedgerEpochInfo <$> getEpochInfo
    let systemStart =
          SystemStart $ posixTimeToUTCTime $ scSlotZeroTime slotConfig
    return $
      MkBlockchainParams
        { protocolParameters
        , systemStart
        , eraHistory
        , -- Staking is not supported
          stakePools = Set.empty
        }

instance (MonadFail m) => MonadQueryUtxo (ClbT m) where
  queryUtxo query = do
    utxos <- fromLedgerUTxO shelleyBasedEra <$> gets getUtxosAtState
    predicate <- mkPredicate
    return $ UTxO $ Map.filterWithKey predicate $ unUTxO utxos
    where
      mkPredicate = case query of
        ByAddresses addresses -> do
          cardanoAddresses <- mapM fromPlutusAddressInMonad addresses
          return $ \_ (TxOut a _ _ _) -> a `elem` cardanoAddresses
        ByTxIns txIns -> return $ \txIn _ -> txIn `elem` txIns

instance (MonadFail m) => MonadSubmitTx (ClbT m) where
  submitResolvedTx :: ResolvedTx -> ClbT m (Either TxSubmittingError TxId)
  submitResolvedTx tx = do
    cardanoTxBodyFromResolvedTx tx >>= \case
      Right (body, TxInMode ShelleyBasedEraBabbage tx') -> do
        result <- sendTx tx'
        case result of
          Success _ _ -> return $ Right $ getTxId body
          _ -> fail "TODO"
      Left e -> return $ Left $ UnhandledAutobalanceError e

instance (MonadFail m) => MonadTest (ClbT m) where
  getTestWalletSks = return $ map intToCardanoSk [1 .. 10]

execOnIsolatedClb :: Value -> ClbT IO a -> IO a
execOnIsolatedClb genesisValue action =
  fst
    <$> runStateT
      (unwrapClbT action)
      (initClb defaultBabbage genesisValue genesisValue)
