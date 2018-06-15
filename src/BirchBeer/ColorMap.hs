{- BirchBeer.ColorMap
Gregory W. Schwartz

Functions to derive different color maps for items and labels.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE QuasiQuotes #-}

module BirchBeer.ColorMap
    ( lchPalette
    , getLabelColorMap
    , getLabelCustomColorMap
    , getLabelMapThresholdContinuous
    , labelToItemColorMap
    , getItemColorMapContinuous
    , getItemColorMapSumContinuous
    , getMarkColorMap
    , getNodeColorMapFromItems
    , getNodeColorMapFromDiversity
    , getGraphColor
    , getNodeColor
    ) where

-- Remote
import Control.Monad (join)
import Data.Colour (AffineSpace (..), withOpacity, blend)
import Data.Colour.Names (black)
import Data.Function (on)
import Data.Int (Int32)
import Data.Maybe (fromMaybe, isNothing)
import Data.Tuple (swap)
import Diagrams.Prelude
import Math.Diversity.Diversity (diversity)
import qualified Control.Foldl as Fold
import qualified Control.Lens as L
import qualified Data.Clustering.Hierarchical as HC
import qualified Data.Colour.CIE as Colour
import qualified Data.Colour.CIE.Illuminant as Colour
import qualified Data.Colour.Palette.BrewerSet as Brewer
import qualified Data.Colour.SRGB as Colour
import qualified Data.Foldable as F
import qualified Data.Graph.Inductive as G
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Sparse.Common as S
import qualified Data.Text as T
import qualified Data.Vector as V
import Safe (atMay)

-- Local
import BirchBeer.Types
import BirchBeer.Utility

-- | Convert CIE-LCH(uv) to Luv.
lchToKolor :: L -> C -> H -> Colour.Colour Double
lchToKolor (L l) (C c) (H h) = Colour.cieLAB Colour.d65 l a b
  where
    a = cos (degreeToRadian h) * c
    b = sin (degreeToRadian h) * c

-- | LCH color palette. Equally spaced hues starting from 30.
lchPalette :: Int -> [Colour.Colour Double]
lchPalette n = fmap
                (\h -> lchToKolor (L 65) (C 100) (H h))
                [30, 30 + (360 / fromIntegral (n - 1)) .. fromIntegral 390]

-- | Get the colors of each label using R to interpolate additional colors.
-- getLabelColorMapR :: Palette -> LabelMap -> R.R s LabelColorMap
-- getLabelColorMapR palette (LabelMap lm) = do
--     let labels    = Set.toAscList . Set.fromList . Map.elems $ lm
--         labelsLen = if odd $ List.genericLength labels
--                         then List.genericLength labels :: Int32
--                         else List.genericLength labels + 1 :: Int32

--     colorsHex <-
--         case palette of
--             -- From https://stackoverflow.com/questions/8197559/emulate-ggplot2-default-color-palette
--             Hcl  -> [r| hues = seq(15, 375, length = labelsLen_hs + 1)
--                         hcl(h = hues, l = 65, c = 100)[1:labelsLen_hs]
--                     |]
--             Set1 ->
--                 if labelsLen > 9
--                     then
--                         [r| library(RColorBrewer)
--                             colorRampPalette(brewer.pal(9, "Set1"))(labelsLen_hs)
--                         |]
--                     else
--                         [r| library(RColorBrewer)
--                             brewer.pal(labelsLen_hs, "Set1")
--                         |]

--     let colors = fmap Colour.sRGB24read . R.dynSEXP $ colorsHex

--     return
--         . LabelColorMap
--         . Map.fromList
--         . flip zip colors
--         $ labels

-- | Get the colors of each label using interpolation.
getLabelColorMap :: Palette -> LabelMap -> LabelColorMap
getLabelColorMap Set1 (LabelMap lm) =
    LabelColorMap . Map.fromList . flip zip colors . Set.toAscList $ labels
  where
    colors = interpColors (Set.size labels) $ Brewer.brewerSet Brewer.Set1 9
    labels = Set.fromList . Map.elems $ lm
getLabelColorMap _ _ = error "Only the Set1 palette is supported now."

-- | Interpolate n colors from a list of colors using linear piecewise
-- interpolation. Inspired by ertes-w.
interpColors :: Int -> [Colour Double] -> [Colour Double]
interpColors n xs0 = if n <= length xs0 then take n xs0 else take n (go 0 xs0)
  where
    di = fromIntegral (length xs0 - 1) / fromIntegral (n - 1)
    go _ [x] = [x]
    go i xs'@(x1 : xs@(x2 : _))
        | i > 1 = go (i - 1) xs
        | otherwise = (blend i x2 x1) : go (i + di) xs'
    go _ _ = []

-- | Get the colors of each label.
getLabelColorMap9 :: LabelMap -> LabelColorMap
getLabelColorMap9 (LabelMap lm) =
    LabelColorMap
        . Map.fromList
        . flip zip (cycle (Brewer.brewerSet Brewer.Set1 9))
        $ labels
  where
    labels = Set.toAscList . Set.fromList . Map.elems $ lm


-- | Get the colors of each label using custom colors.
getLabelCustomColorMap :: CustomColors -> LabelMap -> LabelColorMap
getLabelCustomColorMap (CustomColors cs) (LabelMap lm) =
    LabelColorMap
        . Map.fromList
        . flip zip (cycle cs)
        . Set.toAscList
        . Set.fromList
        . Map.elems
        $ lm

-- | Get the colors of each item from a label.
labelToItemColorMap :: LabelColorMap -> LabelMap -> ItemColorMap
labelToItemColorMap (LabelColorMap lm) =
    ItemColorMap . Map.map (\x -> Map.findWithDefault black x lm) . unLabelMap

-- | Get the colors from a list of expressions from two colors.
getContinuousColor
    :: Colour.Colour Double
    -> Colour.Colour Double
    -> [Double]
    -> [Colour.Colour Double]
getContinuousColor highColor lowColor =
    fmap (\x -> blend x highColor lowColor)
        . Fold.fold
            ( (\xs mi ma -> fmap (minMaxNorm (getExist mi) (getExist ma)) xs)
                    <$> Fold.list
                    <*> Fold.minimum
                    <*> Fold.maximum
            )
  where
    getExist = fromMaybe (error "Feature does not exist or no cells found.")

-- | Get the colors of each item, where the color is determined by features.
getItemColorMapContinuous
    :: (MatrixLike a)
    => Maybe CustomColors -> Feature -> a -> ItemColorMap
getItemColorMapContinuous customColors g mat
    | isNothing col = ItemColorMap Map.empty
    | otherwise = ItemColorMap
                . Map.fromList
                . zip (fmap Id . V.toList . getRowNames $ mat)
                . getContinuousColor highColor lowColor
                . S.toDenseListSV
                . flip S.extractCol (colErr col)
                . getMatrix
                $ mat
  where
    colErr = fromMaybe (error $ "Feature " <> T.unpack (unFeature g) <> " does not exist.")
    col = V.elemIndex g
        . fmap Feature
        . getColNames
        $ mat
    highColor = fromMaybe red $ customColors >>= flip atMay 0 . unCustomColors
    lowColor  = fromMaybe white $ customColors >>= flip atMay 1 . unCustomColors

-- | Get the labels of each item, where the label is determined by a binary high
-- / low features determined by a threshold. Multiple features can be used
-- for combinatorical labeling.
getLabelMapThresholdContinuous
    :: (MatrixLike a)
    => [(Feature, Double)] -> a -> LabelMap
getLabelMapThresholdContinuous gs mat
    | any (isNothing . getCol . fst) gs = LabelMap Map.empty
    | otherwise = LabelMap
                . Map.fromList
                . zip (fmap Id . V.toList . getRowNames $ mat)
                . getCombinatoricLabels
                $ gs'
  where
    getCombinatoricLabels :: [(Feature, Double)] -> [Label]
    getCombinatoricLabels =
        fmap (Label . List.foldl1' (\acc x -> acc <> " " <> x))
            . List.transpose
            . fmap (uncurry getCombinatoricLabelFeature)
    getCombinatoricLabelFeature g v =
        fmap (\x -> unFeature g <> " " <> if x > v then "high" else "low")
            . S.toDenseListSV
            . flip S.extractCol (colErr g $ getCol g)
            . getMatrix
            $ mat
    gs' = List.sortBy (compare `on` fst) gs
    colErr g = fromMaybe (error $ "Feature " <> T.unpack (unFeature g) <> " does not exist.")
    getCol g = V.elemIndex g
             . fmap Feature
             . getColNames
             $ mat

-- | Get the colors of each item, where the color is determined by the sum of
-- features in that cell.
getItemColorMapSumContinuous :: (MatrixLike a) => Maybe CustomColors -> a -> ItemColorMap
getItemColorMapSumContinuous customColors mat =
    ItemColorMap
        . Map.fromList
        . zip (fmap Id . V.toList . getRowNames $ mat)
        . getContinuousColor highColor lowColor
        . fmap sum
        . S.toRowsL
        . getMatrix
        $ mat
  where
    highColor = fromMaybe red $ customColors >>= flip atMay 0 . unCustomColors
    lowColor  = fromMaybe white $ customColors >>= flip atMay 1 . unCustomColors

-- | Use the outgoing edges of a node to define the mark around the node.
-- Min max normalization.
getMarkColorMap :: ClusterGraph a -> MarkColorMap
getMarkColorMap g =
    MarkColorMap . Map.map (withOpacity black) $ valMap
  where
    valMap   = Map.map (minMaxNorm minVal maxVal) . Map.fromList $ valAssoc
    minVal   = minimum . fmap snd $ valAssoc
    maxVal   = maximum . fmap snd $ valAssoc
    valAssoc = fmap nodeValue . G.labEdges . unClusterGraph $ g
    nodeValue (n1, n2, v) = (n1, v)

-- | Get the node color map based on the labels of each item.
getNodeColorMapFromItems
    :: (TreeItem a)
    => ClusterGraph a -> ItemColorMap -> NodeColorMap
getNodeColorMapFromItems gr cm =
    NodeColorMap
        . Map.fromList
        . fmap (\ !n -> (n, getGraphColor (Just cm) . getGraphLeafItems gr $ n))
        . G.nodes
        . unClusterGraph
        $ gr

-- | Get the diversity of each node as the color, treating the leaves separately
-- from the non-leaves.
getNodeColorMapFromDiversity
    :: (TreeItem a, Ord a)
    => Maybe CustomColors
    -> Order
    -> ClusterGraph a
    -> ItemColorMap
    -> NodeColorMap
getNodeColorMapFromDiversity customColors (Order order) gr cm =
    NodeColorMap
        . Map.fromList
        . mappend (zip innerNodes innerColors)
        . zip leafNodes
        $ leafColors
  where
    nodes        = G.nodes . unClusterGraph $ gr
    leafNodes    = fmap fst . F.toList $ getGraphLeaves (unClusterGraph gr) 0
    innerNodes   =
        filter (not . flip Set.member leafNodesSet) nodes
    leafNodesSet = Set.fromList leafNodes
    leafColors   = colors leafNodes
    innerColors  = colors innerNodes
    colors xs    = getContinuousColor highColor lowColor
                 $ fmap (diversity order . F.toList . getGraphLeafItems gr) xs
    highColor    = fromMaybe red $ customColors >>= flip atMay 0 . unCustomColors
    lowColor     = fromMaybe white $ customColors >>= flip atMay 1 . unCustomColors

-- | Get the color of a node, defaulting to black.
getNodeColor :: Maybe NodeColorMap -> G.Node -> Colour Double
getNodeColor cm n =
    fromMaybe black . join . fmap (Map.lookup n . unNodeColorMap) $ cm

-- | Get the a color from a fractional list of colors.
blendColors :: [(Double, Colour Double)] -> Colour Double
blendColors []     = black
blendColors (x:xs) = affineCombo xs . snd $ x

-- | Get the the blended color from a graph node.
getBlendedColor :: (TreeItem a) => Maybe ItemColorMap -> [a] -> Colour Double
getBlendedColor cm = blendColors . getEachFractionColorList cm

-- | Get the color of a path or node in a graph.
getGraphColor
    :: (TreeItem a)
    => Maybe ItemColorMap -> Seq.Seq a -> Colour Double
getGraphColor cm = getBlendedColor cm . F.toList

-- | Get the fraction of each element in a list.
getEachFractionColorList :: (TreeItem a)
                         => Maybe ItemColorMap
                         -> [a]
                         -> [(Double, Colour Double)]
getEachFractionColorList Nothing                  = const [(1, black)]
getEachFractionColorList (Just (ItemColorMap cm)) =
    fmap swap
        . getFractions
        . fmap (flip (Map.findWithDefault black) cm . getId)
