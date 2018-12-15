{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}

module Language.Granule.Checker.Predicates where

{-

This module provides the representation of theorems (predicates)
inside the type checker.

-}

import Data.List (intercalate, (\\))
import GHC.Generics (Generic)

import Language.Granule.Context
import Language.Granule.Syntax.Helpers
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.FirstParameter
import Language.Granule.Syntax.Pretty
import Language.Granule.Syntax.Span
import Language.Granule.Syntax.Type

data Quantifier =
    -- | Universally quantification, e.g. polymorphic
    ForallQ

    -- | Instantiations of universally quantified variables
    | InstanceQ

    -- | Univeral, but bound in a dependent pattern match
    | BoundQ
  deriving (Show, Eq)

instance Pretty Quantifier where
  prettyL l ForallQ   = "forall"
  prettyL l InstanceQ = "exists"
  prettyL l BoundQ    = "pi"

stripQuantifiers :: Ctxt (a, Quantifier) -> Ctxt a
stripQuantifiers = map (\(var, (k, _)) -> (var, k))


-- Represent constraints generated by the type checking algorithm
data Constraint =
    Eq  Span Coeffect Coeffect Type
  | Neq Span Coeffect Coeffect Type
  | ApproximatedBy Span Coeffect Coeffect Type

  -- NonZeroPromotableTo s x c means that:
  --   exists x . (x != 0) and x * 1 = c
  -- This is used to check constraints related to definite unification
  -- which incurrs a consumption effect
  | NonZeroPromotableTo Span Id Coeffect Type
  deriving (Show, Eq, Generic)

instance FirstParameter Constraint Span

-- Used to negate constraints
data Neg a = Neg a
  deriving Show

instance Pretty (Neg Constraint) where
    prettyL l (Neg (Neq _ c1 c2 _)) =
      "Trying to prove that " <> prettyL l c1 <> " /= " <> prettyL l c2

    prettyL l (Neg (Eq _ c1 c2 _)) =
      "Actual grade `" <> prettyL l c1 <>
      "` is not equal to specified grade `" <> prettyL l c2 <> "`"

    prettyL l (Neg (ApproximatedBy _ c1 c2 (TyCon k))) =
      prettyL l c1 <> " is not approximatable by " <> prettyL l c2 <> " for type " <> pretty k
      <> if internalName k == "Nat" then " because Nat denotes precise usage." else ""

    prettyL l (Neg (NonZeroPromotableTo _ _ c _)) = "TODO"


instance Pretty [Constraint] where
    prettyL l constr =
      "---\n" <> (intercalate "\n" . map (prettyL l) $ constr)

instance Pretty Constraint where
    prettyL l (Eq _ c1 c2 _) =
      "(" <> prettyL l c1 <> " == " <> prettyL l c2 <> ")" -- @" <> show s

    prettyL l (Neq _ c1 c2 _) =
        "(" <> prettyL l c1 <> " /= " <> prettyL l c2 <> ")" -- @" <> show s

    prettyL l (ApproximatedBy _ c1 c2 _) =
      "(" <> prettyL l c1 <> " <= " <> prettyL l c2 <> ")" -- @" <> show s

    prettyL l (NonZeroPromotableTo _ _ c _) = "TODO"

-- Represents a predicate generated by the type checking algorithm
data Pred where
    Conj :: [Pred] -> Pred
    Impl :: [Id] -> Pred -> Pred -> Pred
    Con  :: Constraint -> Pred

vars :: Pred -> [Id]
vars (Conj ps) = concatMap vars ps
vars (Impl bounds p1 p2) = (vars p1 <> vars p2) \\ bounds
vars (Con c) = varsConstraint c

varsConstraint :: Constraint -> [Id]
varsConstraint (Eq _ c1 c2 _) = freeVars c1 <> freeVars c2
varsConstraint (Neq _ c1 c2 _) = freeVars c1 <> freeVars c2
varsConstraint (ApproximatedBy _ c1 c2 _) = freeVars c1 <> freeVars c2
varsConstraint (NonZeroPromotableTo _ _ c _) = freeVars c

deriving instance Show Pred
deriving instance Eq Pred

-- Fold operation on a predicate
predFold :: ([a] -> a) -> ([Id] -> a -> a -> a) -> (Constraint -> a) -> Pred -> a
predFold c i a (Conj ps)   = c (map (predFold c i a) ps)
predFold c i a (Impl eVar p p') = i eVar (predFold c i a p) (predFold c i a p')
predFold _ _ a (Con cons)  = a cons

instance Pretty Pred where
  prettyL l =
    predFold
     (intercalate " & ")
     (\s p q ->
         (if null s then "" else "forall " <> intercalate "," (map sourceName s) <> " . ")
      <> "(" <> p <> " -> " <> q <> ")") (prettyL l)
