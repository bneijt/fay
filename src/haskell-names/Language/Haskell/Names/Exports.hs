{-# OPTIONS -fno-warn-name-shadowing #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonoLocalBinds  #-}
{-# LANGUAGE TypeFamilies      #-}
module Language.Haskell.Names.Exports
  ( processExports
  ) where

import           Fay.Compiler.Prelude

import           Fay.Compiler.ModuleT
import           Language.Haskell.Names.GlobalSymbolTable as Global
import           Language.Haskell.Names.ModuleSymbols
import           Language.Haskell.Names.ScopeUtils
import           Language.Haskell.Names.SyntaxUtils
import           Language.Haskell.Names.Types             (Error (..), GName (..), ModuleNameS, NameInfo (..),
                                                           Scoped (..), Symbols (..), mkTy, mkVal, st_origName)

import           Control.Monad.Writer                     (WriterT (WriterT), runWriterT)
import qualified Data.Map                                 as Map
import qualified Data.Set                                 as Set
import           Language.Haskell.Exts

processExports
  :: (MonadModule m, ModuleInfo m ~ Symbols, Data l, Eq l)
  => Global.Table
  -> Module l
  -> m (Maybe (ExportSpecList (Scoped l)), Symbols)
processExports tbl m =
  case getExportSpecList m of
    Nothing ->
      return (Nothing, moduleSymbols tbl m)
    Just exp ->
      liftM (first Just) $ resolveExportSpecList tbl exp

resolveExportSpecList
  :: (MonadModule m, ModuleInfo m ~ Symbols)
  => Global.Table
  -> ExportSpecList l
  -> m (ExportSpecList (Scoped l), Symbols)
resolveExportSpecList tbl (ExportSpecList l specs) =
  liftM (first $ ExportSpecList $ none l) $
  runWriterT $
  mapM (WriterT . resolveExportSpec tbl) specs

resolveExportSpec
  :: (MonadModule m, ModuleInfo m ~ Symbols)
  => Global.Table
  -> ExportSpec l
  -> m (ExportSpec (Scoped l), Symbols)
resolveExportSpec tbl exp =
  case exp of
    EVar l qn -> return $
      case Global.lookupValue qn tbl of
        Global.Error err ->
          (scopeError err exp, mempty)
        Global.Result i ->
          let s = mkVal i
          in
            (EVar (Scoped (Export s) l)
              (Scoped (GlobalValue i) <$> qn), s)
        Global.Special {} -> error "Global.Special in export list?"
    EAbs l ns qn -> return $
      case Global.lookupType qn tbl of
        Global.Error err ->
          (scopeError err exp, mempty)
        Global.Result i ->
          let s = mkTy i
          in
            (EAbs (Scoped (Export s) l) (noScope ns)
              (Scoped (GlobalType i) <$> qn), s)
        Global.Special {} -> error "Global.Special in export list?"
    EThingWith l (EWildcard wcl wcn) qn [] -> return $
      case Global.lookupType qn tbl of
        Global.Error err ->
          (scopeError err exp, mempty)
        Global.Result i ->
          let
            subs = mconcat
              [ mkVal info
              | info <- allValueInfos
              , Just n' <- return $ sv_parent info
              , n' == st_origName i ]
            s = mkTy i <> subs
          in
            ( EThingWith (Scoped (Export s) l)
                         (EWildcard (Scoped (Export s) wcl) wcn)
                         (Scoped (GlobalType i) <$> qn)
                         []
            , s
            )
        Global.Special {} -> error "Global.Special in export list?"
    EThingWith _ (EWildcard _ _) _qn _cns -> error "Name resolution: CNames are not supported in wildcard exports"
    EThingWith l (NoWildcard wcl) qn cns -> return $
      case Global.lookupType qn tbl of
        Global.Error err ->
          (scopeError err exp, mempty)
        Global.Result i ->
          let
            (cns', subs) =
              resolveCNames
                (Global.toSymbols tbl)
                (st_origName i)
                (\cn -> ENotInScope (UnQual (ann cn) (unCName cn))) -- FIXME better error
                cns
            s = mkTy i <> subs
          in
            ( EThingWith (Scoped (Export s) l)
                         (NoWildcard (Scoped (Export s) wcl))
                         (Scoped (GlobalType i) <$> qn)
                         cns'
            , s
            )
        Global.Special {} -> error "Global.Special in export list?"
    EModuleContents _ (ModuleName _ mod) ->
      -- FIXME ambiguity check
      let
        filterByPrefix
          :: Ord i
          => ModuleNameS
          -> Map.Map GName (Set.Set i)
          -> Set.Set i
        filterByPrefix prefix m =
          Set.unions
            [ i | (GName { gModule = prefix' }, i) <- Map.toList m, prefix' == prefix ]

        filterEntities
          :: Ord i
          => Map.Map GName (Set.Set i)
          -> Set.Set i
        filterEntities ents =
          Set.intersection
            (filterByPrefix mod ents)
            (filterByPrefix ""  ents)

        eVals = filterEntities $ Global.values tbl
        eTyps = filterEntities $ Global.types tbl

        s = Symbols eVals eTyps
      in
        return (Scoped (Export s) <$> exp, s)
  where
    allValueInfos =
      Set.toList $ Map.foldl' Set.union Set.empty $ Global.values tbl
