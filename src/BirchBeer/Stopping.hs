{- BirchBeer.Stopping
Gregory W. Schwartz

Collects helper functions used in the stopping criteria.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module BirchBeer.Stopping
    ( stepCut
    , stepCutDendrogram
    , sizeCut
    , sizeCutDendrogram
    , proportionCut
    , proportionCutDendrogram
    , distanceCut
    , distanceCutDendrogram
    , getSize
    , getSizeDend
    , getDistance
    , getDistanceDend
    , getProportion
    , getProportionDend
    , smartCut
    , smartCutDend
    ) where

-- Remote
import Control.Monad.State (MonadState (..), State (..), evalState, execState, modify)
import Data.Function (on)
import Data.Int (Int32)
import Data.List (genericLength, maximumBy)
import Data.Maybe (fromMaybe, catMaybes)
import Data.Monoid ((<>))
import Data.Tree (Tree (..), flatten)
import qualified Control.Lens as L
import qualified Data.Clustering.Hierarchical as HC
import qualified Data.Graph.Inductive as G
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Statistics.Quantile as S

-- Local
import BirchBeer.Types
import BirchBeer.Utility

-- | Cut a dendrogram based off of the number of steps from the root, combining
-- the results.
stepCutDendrogram :: (Monoid a) => Int -> HC.Dendrogram a -> HC.Dendrogram a
stepCutDendrogram _ b@(HC.Leaf x)       = b
stepCutDendrogram 0 b@(HC.Branch d l r) = branchToLeafDend b
stepCutDendrogram !n (HC.Branch d l r) =
    HC.Branch d (stepCutDendrogram (n - 1) l) (stepCutDendrogram (n - 1) r)

-- | Cut a tree based off of the number of steps from the root, combining
-- the results.
stepCut :: (Monoid a) => Int -> Tree a -> Tree a
stepCut _ b@(Node { subForest = [] }) = b
stepCut 0 b = branchToLeaf b
stepCut !n b@(Node { subForest = xs }) =
  b { subForest = fmap (stepCut (n - 1)) xs }

-- | Cut a dendrogram based off of the minimum size of a leaf.
sizeCutDendrogram
    :: (Monoid (t a), Traversable t)
    => Int -> HC.Dendrogram (t a) -> HC.Dendrogram (t a)
sizeCutDendrogram _ b@(HC.Leaf x) = branchToLeafDend b
sizeCutDendrogram n b@(HC.Branch d l r) =
    if getSizeDend l < n || getSizeDend r < n
        then branchToLeafDend b
        else HC.Branch d (sizeCutDendrogram n l) (sizeCutDendrogram n r)

-- | Cut a tree based off of the minimum size of a leaf.
sizeCut
    :: (Monoid (t a), Traversable t)
    => Int -> Tree (TreeNode (t a)) -> Tree (TreeNode (t a))
sizeCut _ b@(Node { subForest = [] }) = branchToLeaf b
sizeCut n b@(Node { subForest = xs }) =
    if any ((< n) . getSize) xs
        then branchToLeaf b
        else b { subForest = fmap (sizeCut n) xs }

-- | Cut a dendrogram based off of the proportion size of a leaf. Will absolute
-- log2 transform before comparing, so if the cutoff size is 0.5 or 2 (twice as
-- big or half as big), the result is the same. Stops when the node proportion
-- is larger than the input, although leaving the children as well.
proportionCutDendrogram
    :: (Monoid (t a), Traversable t)
    => Double -> HC.Dendrogram (t a) -> HC.Dendrogram (t a)
proportionCutDendrogram _ (HC.Leaf x) = HC.Leaf x
proportionCutDendrogram _ b@(HC.Branch _ (HC.Leaf _) (HC.Leaf _)) = b
proportionCutDendrogram n b@(HC.Branch d l@(HC.Leaf ls) r) =
    if (absLog2 $ (lengthElementsDend l) / (lengthElementsDend r))
       > absLog2 n
        then HC.Branch d l (branchToLeafDend r)
        else HC.Branch d l (proportionCutDendrogram n r)
proportionCutDendrogram n b@(HC.Branch d l r@(HC.Leaf rs)) =
    if (absLog2 $ (lengthElementsDend l) / (lengthElementsDend r))
       > absLog2 n
        then HC.Branch d (branchToLeafDend l) r
        else HC.Branch d (proportionCutDendrogram n l) r
proportionCutDendrogram n b@(HC.Branch d l r) =
    if (absLog2 $ (lengthElementsDend l) / (lengthElementsDend r)) > absLog2 n
        then HC.Branch d (branchToLeafDend l) (branchToLeafDend r)
        else HC.Branch
                d
                (proportionCutDendrogram n l)
                (proportionCutDendrogram n r)

-- | Cut a tree based off of the proportion size of a leaf, comparing maximum
-- size to minimum size leaves. Will absolute log2 transform before comparing,
-- so if the cutoff size is 0.5 or 2 (twice as big or half as big), the result
-- is the same. Stops when the node proportion is larger than the input,
-- although leaving the children as well.
proportionCut :: (Monoid (t a), Traversable t)
              => Double -> Tree (TreeNode (t a)) -> Tree (TreeNode (t a))
proportionCut _ b@(Node { subForest = [] }) = b
proportionCut _ b@(all isLeaf . subForest -> True) = b
proportionCut n b@(Node { subForest = xs }) =
    if (absLog2 $ (maximum . fmap getSize $ xs) / (minimum . fmap getSize $ xs))
       > absLog2 n
        then b { subForest = fmap branchToLeaf xs }
        else b { subForest = fmap (proportionCut n) xs }

-- | Cut a dendrogram based off of the distance, keeping up to and including the
-- children of the stopping vertex. Stop is distance is less than the input
-- distance.
distanceCutDendrogram
    :: (Monoid (t a), Traversable t)
    => Double -> HC.Dendrogram (t a) -> HC.Dendrogram (t a)
distanceCutDendrogram _ b@(HC.Leaf _) = branchToLeafDend b
distanceCutDendrogram _ b@(HC.Branch _ (HC.Leaf _) (HC.Leaf _)) = b
distanceCutDendrogram d (HC.Branch d' l@(HC.Leaf _) r) =
    if d' < d
        then HC.Branch d' l $ branchToLeafDend r
        else HC.Branch d' l (distanceCutDendrogram d r)
distanceCutDendrogram d (HC.Branch d' l r@(HC.Leaf rs)) =
    if d' < d
        then HC.Branch d' (branchToLeafDend l) r
        else HC.Branch d' (distanceCutDendrogram d l) r
distanceCutDendrogram d (HC.Branch d' l r) =
    if d' < d
        then HC.Branch d' (branchToLeafDend l) (branchToLeafDend r)
        else
            HC.Branch d' (distanceCutDendrogram d l) (distanceCutDendrogram d r)

-- | Cut a tree based off of the distance, keeping up to and including the
-- children of the stopping vertex. Stop is distance is less than the input
-- distance.
distanceCut :: (Monoid a) => Double -> Tree (TreeNode a) -> Tree (TreeNode a)
distanceCut _ b@(Node { subForest = [] }) = b
distanceCut _ b@(all isLeaf . subForest -> True) = b
distanceCut d b =
    if (L.view distance . rootLabel $ b) < Just d
        then b { subForest = fmap branchToLeaf . subForest $ b }
        else b { subForest = fmap (distanceCut d) . subForest $ b }

-- | Get a property about each node in a dendrogram.
getNodeInfoDend :: (HC.Dendrogram a -> b) -> HC.Dendrogram a -> [b]
getNodeInfoDend f b@(HC.Leaf _)       = [f b]
getNodeInfoDend f b@(HC.Branch d l r) =
  f b : (getNodeInfoDend f l <> getNodeInfoDend f r)

-- | Get a property about each node in a tree.
getNodeInfo :: (Tree a -> b) -> Tree a -> [b]
getNodeInfo f b = f b : (concatMap (getNodeInfo f) . subForest $ b)

-- | Get the length of elements in a dendrogram.
getSizeDend :: (Monoid (t a), Traversable t, Num b) => HC.Dendrogram (t a) -> b
getSizeDend = lengthElementsDend

-- | Get the length of elements in a tree.
getSize :: (Monoid (t a), Traversable t, Num b) => Tree (TreeNode (t a)) -> b
getSize = lengthElementsTree

-- | Get the distance of an item in a dendrogram.
getDistanceDend :: HC.Dendrogram a -> Maybe Double
getDistanceDend (HC.Leaf _) = Nothing
getDistanceDend (HC.Branch d _ _) = Just d

-- | Get the distance of an item in a tree.
getDistance :: Tree (TreeNode a) -> Maybe Double
getDistance = L.view distance . rootLabel

-- | Get the proportion of the children sizes in a dendrogram.
getProportionDend
    :: (Monoid (t a), Traversable t)
    => HC.Dendrogram (t a) -> Maybe Double
getProportionDend (HC.Leaf _) = Nothing
getProportionDend (HC.Branch _ l r) =
    Just . absLog2 $ fromIntegral (getSizeDend l) / fromIntegral (getSizeDend r)

-- | Get the proportion of the children sizes in a tree.
getProportion :: (Monoid (t a), Traversable t)
              => Tree (TreeNode (t a)) -> Maybe Double
getProportion (Node { subForest = [] }) = Nothing
getProportion (Node { subForest = xs }) =
    Just . absLog2 $ (maximum . fmap getSize $ xs) / (minimum . fmap getSize $ xs)

-- | Get the smart cut value of a dendrogram.
smartCutDend
    :: (Monoid (t a), Traversable t)
    => Double
    -> (HC.Dendrogram (t a) -> Maybe Double)
    -> HC.Dendrogram (t a)
    -> Double
smartCutDend n f dend = median S.s xs + (n * mad S.s xs)
  where
    xs = V.fromList . catMaybes . getNodeInfoDend f $ dend

-- | Get the smart cut value of a tree.
smartCut ::
  Double -> (Tree (TreeNode a) -> Maybe Double) -> Tree (TreeNode a) -> Double
smartCut n f tree = median S.s xs + (n * mad S.s xs)
  where
    xs = V.fromList . catMaybes . getNodeInfo f $ tree
