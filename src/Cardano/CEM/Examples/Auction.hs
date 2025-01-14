{-# LANGUAGE NoPolyKinds #-}

module Cardano.CEM.Examples.Auction where

import PlutusTx.Prelude
import Prelude qualified

import Data.Data (Proxy (..))
import Data.Map qualified as Map

import PlutusLedgerApi.V1.Crypto (PubKeyHash)
import PlutusLedgerApi.V1.Interval qualified as Interval
import PlutusLedgerApi.V1.Time (POSIXTime)
import PlutusLedgerApi.V1.Value (CurrencySymbol (..), TokenName (..), singleton)
import PlutusLedgerApi.V2 (Address, ToData, Value)
import PlutusTx qualified
import PlutusTx.Show.TH (deriveShow)

import Cardano.CEM
import Cardano.CEM.Stages
import Data.Spine

-- Simple no-deposit auction

data SimpleAuction

data Bid = MkBet
  { better :: PubKeyHash
  , betAmount :: Integer
  }
  deriving stock (Prelude.Eq, Prelude.Show)

data SimpleAuctionStage = Open | Closed
  deriving stock (Prelude.Eq, Prelude.Show)

data SimpleAuctionStageParams
  = NoControl
  | CanCloseAt POSIXTime
  deriving stock (Prelude.Eq, Prelude.Show)

instance Stages SimpleAuctionStage where
  type StageParams SimpleAuctionStage = SimpleAuctionStageParams
  stageToOnChainInterval NoControl _ = Interval.always
  -- Example: logical error
  stageToOnChainInterval (CanCloseAt time) Open = Interval.to time
  stageToOnChainInterval (CanCloseAt time) Closed = Interval.from time

data SimpleAuctionState
  = NotStarted
  | CurrentBid Bid
  | Winner Bid
  deriving stock (Prelude.Eq, Prelude.Show)

data SimpleAuctionParams = MkAuctionParams
  { seller :: PubKeyHash
  , lot :: Value
  }
  deriving stock (Prelude.Eq, Prelude.Show)

data SimpleAuctionTransition
  = Create
  | Start
  | MakeBid Bid
  | Close
  | Buyout
  deriving stock (Prelude.Eq, Prelude.Show)

PlutusTx.unstableMakeIsData ''Bid
PlutusTx.unstableMakeIsData 'MkAuctionParams
PlutusTx.unstableMakeIsData 'NotStarted
PlutusTx.unstableMakeIsData 'MakeBid
PlutusTx.unstableMakeIsData ''SimpleAuctionStage
PlutusTx.unstableMakeIsData ''SimpleAuctionStageParams
deriveShow ''SimpleAuction

deriveSpine ''SimpleAuctionTransition
deriveSpine ''SimpleAuctionState

instance CEMScript SimpleAuction where
  type Stage SimpleAuction = SimpleAuctionStage
  type Params SimpleAuction = SimpleAuctionParams

  type State SimpleAuction = SimpleAuctionState

  type Transition SimpleAuction = SimpleAuctionTransition

  transitionStage Proxy =
    Map.fromList
      [ (CreateSpine, (Open, Nothing, Just NotStartedSpine))
      , (StartSpine, (Open, Just NotStartedSpine, Just CurrentBidSpine))
      , (MakeBidSpine, (Open, Just CurrentBidSpine, Just CurrentBidSpine))
      , (CloseSpine, (Closed, Just CurrentBidSpine, Just WinnerSpine))
      , (BuyoutSpine, (Closed, Just WinnerSpine, Nothing))
      ]

  {-# INLINEABLE transitionSpec #-}
  transitionSpec params state transition = case (state, transition) of
    (Nothing, Create) ->
      Right
        $ MkTransitionSpec
          { constraints =
              [ MkTxFanC
                  In
                  (MkTxFanFilter (ByPubKey $ seller params) Anything)
                  (SumValueEq $ lot params)
              , nextState NotStarted
              ]
          , signers = [seller params]
          }
    (Just NotStarted, Start) ->
      Right
        $ MkTransitionSpec
          { constraints = [nextState (CurrentBid initialBid)]
          , signers = [seller params]
          }
    (Just (CurrentBid currentBet), MakeBid newBet) ->
      -- Example: could be parametrized with param or typeclass
      if betAmount newBet > betAmount currentBet
        then
          Right
            $ MkTransitionSpec
              { constraints = [nextState (CurrentBid newBet)]
              , signers = [better newBet]
              }
        else Left "Wrong Bid amount"
    (Just (CurrentBid currentBet), Close) ->
      Right
        $ MkTransitionSpec
          { constraints = [nextState (Winner currentBet)]
          , signers = [seller params]
          }
    (Just (Winner winnerBet), Buyout {}) ->
      Right
        $ MkTransitionSpec
          { constraints =
              [ -- Example: In constraints redundant for on-chain
                MkTxFanC
                  In
                  (MkTxFanFilter (ByPubKey (better winnerBet)) Anything)
                  (SumValueEq $ betAdaValue winnerBet)
              , MkTxFanC
                  Out
                  (MkTxFanFilter (ByPubKey (better winnerBet)) Anything)
                  (SumValueEq $ lot params)
              , MkTxFanC
                  Out
                  (MkTxFanFilter (ByPubKey (seller params)) Anything)
                  (SumValueEq $ betAdaValue winnerBet)
              ]
          , signers = [better winnerBet]
          }
    _ -> Left "Incorrect state for transition"
    where
      initialBid = MkBet (seller params) 0
      nextState state =
        MkTxFanC
          Out
          (MkTxFanFilter BySameScript (bySameCEM state))
          (SumValueEq $ lot params)
      betAdaValue = adaValue . betAmount
      adaValue =
        singleton (CurrencySymbol emptyByteString) (TokenName emptyByteString)
