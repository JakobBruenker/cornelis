{-# LANGUAGE OverloadedStrings #-}

module Cornelis.Pretty where

import           Cornelis.Offsets (toBytes, Offset (Offset))
import qualified Cornelis.Types as C
import qualified Cornelis.Types as X
import           Cornelis.Types hiding (Type)
import           Data.Bool (bool)
import           Data.Function (on)
import           Data.Int
import           Data.List (sortOn, groupBy)
import qualified Data.Text as T
import           Prettyprinter
import           Prettyprinter.Internal.Type

data HighlightGroup
  = Keyword
  | Normal
  | Type
  | Operator
  | Identifier
  | Constant
  | Number
  | Comment
  | Todo
  | String
  | Folded
  | Structure
  | Title
  | PreProc
  | Error
  | WarningMsg
  deriving (Eq, Ord, Show)

data InfoHighlight a = InfoHighlight
  { ihl_start :: (Int64, Int64)
  , ihl_end :: a
  , ihl_group :: HighlightGroup
  }
  deriving (Eq, Ord, Show, Functor)

spanInfoHighlights
    :: InfoHighlight (Int64, Int64)
    -> [InfoHighlight Int64]
spanInfoHighlights ih@(InfoHighlight (sl, sc) (el, ec) hg)
  | sl == el = pure $ fmap snd ih
  | otherwise
      = InfoHighlight (sl, sc) (-1) hg
      : InfoHighlight (el, 0) ec hg
      : fmap (\l -> InfoHighlight (l, 0) (-1) hg) [sl + 1 .. el - 1]


renderWithHlGroups
    :: SimpleDocStream HighlightGroup
    -> ([InfoHighlight (Int64, Int64)], SimpleDocStream a)
renderWithHlGroups = go [] 0 0
  where
    go
      :: [InfoHighlight ()]
      -> Int64
      -> Int64
      -> SimpleDocStream HighlightGroup
      -> ([InfoHighlight (Int64, Int64)], SimpleDocStream a)
    go _ _ _ SFail = pure SFail
    go _ _ _ SEmpty = pure SEmpty
    go st r c (SChar c' sds) =
      SChar c' <$> go st r (c + fromIntegral (toBytes (T.singleton c') $ Offset 1)) sds
    go st r c (SText n txt sds) =
      SText n txt <$> go st r (c + fromIntegral (toBytes txt $ Offset $ fromIntegral n)) sds
    go st r _ (SLine n sds) = SLine n <$> go st (r + 1) (fromIntegral n) sds
    go st r c (SAnnPush hg sds) = go (InfoHighlight (r, c) () hg : st) r c sds
    go [] _ _ (SAnnPop _) = error "popping an annotation that doesn't exist"
    go (ih : ihs) r c (SAnnPop sds) = do
      sds' <- go ihs r c sds
      ([(r, c) <$ ih], sds')


prettyType :: C.Type -> Doc HighlightGroup
prettyType (C.Type ty) = annotate Type $ sep $ fmap pretty $ T.lines ty


groupScopeSet :: [InScope] -> [[InScope]]
groupScopeSet
  = sortOn (is_refied_name . head)
  . fmap (sortOn is_refied_name)
  . groupBy (on (==) is_type)
  . sortOn is_type


prettyGoals :: DisplayInfo -> Doc HighlightGroup
prettyGoals (AllGoalsWarnings _ _ errs _) | not $ null errs =
  annotate Error $ vcat $ fmap (pretty . getMessage) errs
prettyGoals (AllGoalsWarnings vis invis _ warns) =
  vcat $ punctuate hardline $ filter (not . isEmpty)
    [ section "Warnings" warns $ annotate WarningMsg . pretty . getMessage
    , section "Visible Goals" vis $
        prettyGoal . fmap (mappend "?" . T.pack . show . ip_id)
    , section "Invisible Goals" invis $ prettyGoal . fmap np_name
    ]
prettyGoals (GoalSpecific _ scoped ty Nothing) = vcat
  [ annotate Title "Goal:" <+> prettyType ty
  , mconcat $ replicate 60 "—"
  , vcat $ fmap prettyInScopeSet $ groupScopeSet scoped
  ]
prettyGoals (GoalSpecific _ scoped ty (Just have)) = vcat
  [ annotate Title "Goal:" <+> prettyType ty
  , annotate Title "Have:" <+> prettyType have
  , mconcat $ replicate 60 "—"
  , vcat $ fmap prettyInScopeSet $ groupScopeSet scoped
  ]
prettyGoals (HelperFunction sig) =
  section "Helper Function"
    [ mempty
    , annotate Type $ pretty sig
    , mempty
    , annotate Comment $ parens "copied to \" register"
    ] id
prettyGoals (WhyInScope msg) = pretty msg
prettyGoals (NormalForm expr) = pretty expr
prettyGoals (DisplayError err) = annotate Error $ pretty err
prettyGoals (UnknownDisplayInfo v) = annotate Error $ pretty $ show v

isEmpty :: Doc HighlightGroup -> Bool
isEmpty Empty = True
isEmpty _ = False


section
    :: Doc HighlightGroup
    -> [a]
    -> (a -> Doc HighlightGroup)
    -> Doc HighlightGroup
section _ [] _ = mempty
section doc as f = vcat $
  annotate Title (doc <> ":") : fmap f as


prettyName :: Text -> Doc HighlightGroup
prettyName = prettyVisibleName True


prettyVisibleName :: Bool -> Text -> Doc HighlightGroup
prettyVisibleName False t = annotate Comment $ "(" <> pretty t <> ")"
prettyVisibleName True t = annotate Identifier $ pretty t

prettyInScope :: InScope -> Doc HighlightGroup
prettyInScope (InScope reified _ in_scope ty) =
  hsep
    [ prettyGoal $ GoalInfo reified ty
    , bool
        (pretty (replicate 6 ' ') <+> annotate Comment (parens "not in scope"))
        mempty
        in_scope
    ]

prettyInScopeSet :: [InScope] -> Doc HighlightGroup
prettyInScopeSet is =
  let ty = is_type $ head is
   in prettyManyGoals is ty

prettyManyGoals :: [InScope] -> X.Type -> Doc HighlightGroup
prettyManyGoals is ty =
  hang 4 $ sep
    [ hsep $
        fmap (\i -> prettyVisibleName (is_in_scope i) $ is_refied_name i) is <> [":"]
    , prettyType ty
    ]

prettyGoal :: GoalInfo Text -> Doc HighlightGroup
prettyGoal (GoalInfo name ty) =
  hang 4 $ sep
    [ prettyName name <+> ":"
    , prettyType ty
    ]

