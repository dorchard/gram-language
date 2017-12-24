{-# LANGUAGE ImplicitParams #-}

module Checker.Substitutions where

import Context
import Syntax.Expr
import Syntax.Pretty
import Checker.Kinds
import Checker.Monad
import Control.Monad.Trans.Maybe
import Data.Functor.Identity
import Control.Monad.Reader.Class
import Utils

-- For doctest:
-- $setup
-- >>> :set -XImplicitParams

{-| Take a context of 'a' and a subhstitution for 'a's (also a context)
  apply the substitution returning a pair of contexts, one for parts
  of the context where a substitution occurred, and one where substitution
  did not occur
>>> let ?globals = defaultGlobals in evalChecker initState [] (runMaybeT $ substCtxt  [("y", TyInt 0)] [("x", Linear (TyVar "x")), ("y", Linear (TyVar "y")), ("z", Discharged (TyVar "z") (CVar "b"))])
Just ([("y",Linear (TyInt 0))],[("x",Linear (TyVar "x")),("z",Discharged (TyVar "z") (CVar "b"))])
-}

substCtxt :: (?globals :: Globals) => Ctxt Type -> Ctxt Assumption
  -> MaybeT Checker (Ctxt Assumption, Ctxt Assumption)
substCtxt _ [] = return ([], [])
substCtxt subst ((v, x):ctxt) = do
  (substituteds, unsubstituteds) <- substCtxt subst ctxt
  (v', x') <- substAssumption subst (v, x)
  if (v', x') == (v, x)
    then return (substituteds, (v, x) : unsubstituteds)
    else return ((v, x') : substituteds, unsubstituteds)

-- | rewrite a type using a unifier (map from type vars to types)
substType :: Ctxt Type -> Type -> Type
substType ctx = runIdentity .
    typeFoldM (baseTypeFold { tfTyVar = varSubst })
  where
    varSubst v =
       case lookup v ctx of
         Just t -> return t
         Nothing -> mTyVar v

substAssumption :: (?globals :: Globals) => Ctxt Type -> (Id, Assumption)
  -> MaybeT Checker (Id, Assumption)
substAssumption subst (v, Linear t) =
    return $ (v, Linear (substType subst t))
substAssumption subst (v, Discharged t c) = do
    coeffectSubst <- mapMaybeM convertSubst subst
    return $ (v, Discharged (substType subst t) (substCoeffect coeffectSubst c))
  where
    -- Convert a single type substitution (type variable, type pair) into a
    -- coeffect substitution
    convertSubst :: (Id, Type) -> MaybeT Checker (Maybe (Id, Coeffect))
    convertSubst (v, t) = do
      k <- inferKindOfType nullSpan t
      case k of
        KConstr "Nat=" -> do
          c <- compileNatKindedTypeToCoeffect nullSpan t
          return $ Just (v, c)
        _ -> return $ Nothing
    -- mapM combined with the filtering behaviour of mapMaybe
    mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
    mapMaybeM f [] = return []
    mapMaybeM f (x:xs) = do
      y <- f x
      ys <- mapMaybeM f xs
      case y of
        Just y' -> return $ y' : ys
        Nothing -> return $ ys

compileNatKindedTypeToCoeffect :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Coeffect
compileNatKindedTypeToCoeffect s (TyInfix op t1 t2) = do
  t1' <- compileNatKindedTypeToCoeffect s t1
  t2' <- compileNatKindedTypeToCoeffect s t2
  case op of
    "+"   -> return $ CPlus t1' t2'
    "*"   -> return $ CTimes t1' t2'
    "\\/" -> return $ CJoin t1' t2'
    "/\\" -> return $ CMeet t1' t2'
    _     -> halt $ UnboundVariableError (Just s) $ "Type-level operator " ++ op
compileNatKindedTypeToCoeffect _ (TyInt n) =
  return $ CNat Discrete n
compileNatKindedTypeToCoeffect _ (TyVar v) =
  return $ CVar v
compileNatKindedTypeToCoeffect s t =
  halt $ KindError (Just s) $ "Type " ++ pretty t ++ " does not have kind "
                       ++ pretty (CConstr "Nat=")

{- | Perform a substitution on a coeffect based on a context mapping
     variables to coeffects -}
substCoeffect :: Ctxt Coeffect -> Coeffect -> Coeffect
substCoeffect rmap (CPlus c1 c2) = let
    c1' = substCoeffect rmap c1
    c2' = substCoeffect rmap c2
    in CPlus c1' c2'

substCoeffect rmap (CJoin c1 c2) = let
    c1' = substCoeffect rmap c1
    c2' = substCoeffect rmap c2
    in CJoin c1' c2'

substCoeffect rmap (CMeet c1 c2) = let
    c1' = substCoeffect rmap c1
    c2' = substCoeffect rmap c2
    in CMeet c1' c2'

substCoeffect rmap (CTimes c1 c2) = let
    c1' = substCoeffect rmap c1
    c2' = substCoeffect rmap c2
    in CTimes c1' c2'

substCoeffect rmap (CVar v) =
    case lookup v rmap of
      Just c  -> c
      Nothing -> CVar v

substCoeffect _ c@CNat{}   = c
substCoeffect _ c@CNatOmega{} = c
substCoeffect _ c@CFloat{} = c
substCoeffect _ c@CInfinity{}  = c
substCoeffect _ c@COne{}   = c
substCoeffect _ c@CZero{}  = c
substCoeffect _ c@Level{}  = c
substCoeffect _ c@CSet{}   = c
substCoeffect _ c@CSig{}   = c

-- | Apply a name map to a type to rename the type variables
renameType :: [(Id, Id)] -> Type -> Type
renameType rmap t =
    runIdentity $
      typeFoldM (baseTypeFold { tfBox   = renameBox rmap
                              , tfTyVar = renameTyVar rmap }) t
  where
    renameBox renameMap c t = do
      let c' = substCoeffect (map (\(v, var) -> (v, CVar var)) renameMap) c
      let t' = renameType renameMap t
      return $ Box c' t'
    renameTyVar renameMap v =
      case lookup v renameMap of
        Just v' -> return $ TyVar v'
        -- Shouldn't happen
        Nothing -> return $ TyVar v

unrenameType :: Type -> MaybeT Checker Type
unrenameType t = do
  nameMap <- ask
  return $ renameType nameMap t

unrenameAssumption :: Assumption -> MaybeT Checker Assumption
unrenameAssumption (Linear t) = do
  t' <- unrenameType t
  return (Linear t')
unrenameAssumption (Discharged t c) = do
  t' <- unrenameType t
  return (Discharged t' c)
