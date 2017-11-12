{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module IRBuilder (
  -- ** Builder Monad
  IRBuilder,
  IRBuilderState,
  runIRBuilder,
  emptyIRBuilder,

  -- ** Module
  block,
  function,

  -- ** Instructions
  fadd,
  fmul,
  fsub,
  fdiv,
  frem,
  add,
  mul,
  sub,
  udiv,
  sdiv,
  urem,
  shl,
  lshr,
  ashr,
  and,
  or,
  xor,
  alloca,
  load,
  store,
  gep,
  trunc,
  zext,
  sext,
  fptoui,
  fptosi,
  uitofp,
  sitofp,
  ptrtoint,
  inttoptr,
  bitcast,
  icmp,
  fcmp,
  br,
  call,
  switch,
  select,
  condBr,
  cons,
  phi,
  ret,
  retVoid,

  -- ** Low-level
  emitDefn,
  emitInstr,
  emitTerm,
) where

import Prelude hiding (and, or)

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.State.Strict

import Data.Word
import Data.Coerce
import Data.Map as Map
import Data.Monoid
import Data.Text.Lazy.IO as T
import Data.ByteString.Short as BS

import LLVM.Typed
import LLVM.Pretty
import LLVM.AST hiding (function)
import LLVM.AST.Type as AST
import LLVM.AST.Name
import LLVM.AST.Global
import LLVM.AST.ParameterAttribute
import qualified LLVM.AST as AST
import qualified LLVM.AST.Float as F
import qualified LLVM.AST.CallingConvention as CC
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.FloatingPointPredicate as FP

-- | This provides a uniform API for creating instructions and inserting them
-- into a basic block: either at the end of a BasicBlock, or at a specific
-- location in a block.
newtype IRBuilder a = IRBuilder (State IRBuilderState a)
  deriving (Functor, Applicative, Monad, MonadFix, MonadState IRBuilderState)

-- | A partially constructed block as a sequence of instructions
data PartialBlock = PartialBlock
  { partialName :: Name
  , partialInstrs :: SnocList (Named Instruction)
  , partialTerm :: Maybe (Named Terminator)
  }

emptyPartialBlock :: Name -> PartialBlock
emptyPartialBlock nm = PartialBlock nm mempty Nothing

newtype SnocList a = SnocList { unSnocList :: Dual [a] }
  deriving (Eq, Show, Monoid)

snoc :: SnocList a -> a -> SnocList a
snoc (SnocList (Dual xs)) x = SnocList $ Dual $ x : xs

getSnocList :: SnocList a -> [a]
getSnocList = reverse . getDual . unSnocList

-- | Builder monad state
data IRBuilderState = IRBuilderState
  { builderDefs  :: SnocList AST.Definition
  , builderSupply :: Word
  , builderBlock  :: PartialBlock
  , builderBlocks :: SnocList BasicBlock
  }

emptyIRBuilder :: IRBuilderState
emptyIRBuilder = IRBuilderState
  { builderDefs = mempty
  , builderSupply = 0
  , builderBlock  = emptyPartialBlock "entry"
  , builderBlocks = mempty
  }

-- | Evaluate IRBuilder to a list of definitions
runIRBuilder :: IRBuilderState -> IRBuilder a -> [AST.Definition]
runIRBuilder mod (IRBuilder m) = getSnocList $ builderDefs (execState m mod)

emptyModule :: ShortByteString -> AST.Module
emptyModule label = defaultModule { moduleName = label }

-- | Generate fresh name
fresh :: IRBuilder Name
fresh = do
  n <- gets builderSupply
  modify $ \s -> s { builderSupply = 1 + n }
  pure (UnName n)

-------------------------------------------------------------------------------
-- State Manipulation
-------------------------------------------------------------------------------

-- | Emit instruction
emitInstr
  :: Type -- ^ Return type
  -> Instruction
  -> IRBuilder Operand
emitInstr retty instr = do
  bb <- gets builderBlock
  nm <- fresh
  modify $ \s -> s
    { builderBlock = bb
      { partialInstrs = partialInstrs bb `snoc` (nm := instr)
      }
    }
  pure (localRef retty nm)

-- | Add definition to current IRBuilder.
emitDefn :: Definition -> IRBuilder ()
emitDefn d = do
  defs <- gets builderDefs
  modify $ \s -> s { builderDefs = defs `snoc` d }

-- | Emit terminator
emitTerm :: Terminator -> IRBuilder ()
emitTerm term = do
  bb <- gets builderBlock
  modify $ \s -> s
    { builderBlock = bb
      { partialTerm = Just (Do term)
      }
    }
  pure ()


-------------------------------------------------------------------------------
-- Toplevel
-------------------------------------------------------------------------------

-- | Emit block
block
  :: Name                         -- ^ Block name
  -> IRBuilder Name
block nm = do
  bb <- gets builderBlock
  modify $ \s -> s { builderBlock = emptyPartialBlock nm }
  let instrs' = getSnocList $ partialInstrs bb
  case (instrs', partialTerm bb) of
    ([], Nothing) -> return ()
    _ -> do
      let
        newBb = case partialTerm bb of
          Nothing   -> BasicBlock (partialName bb) instrs' (Do (Ret Nothing []))
          Just term -> BasicBlock (partialName bb) instrs' term
      modify $ \s -> s
        { builderBlocks = builderBlocks s `snoc` newBb
        }
  pure nm

-- | Emit function
function
  :: Name                  -- ^ Function name
  -> [(Type, Name)]        -- ^ Parameters (non-variadic)
  -> Type                  -- ^ Return type
  -> ([Operand] -> IRBuilder ()) -- ^ Function generation
  -> IRBuilder Operand
function label argtys retty body = do
  startBlock <- gets builderBlock
  startBlocks <- gets builderBlocks
  startSupply <- gets builderSupply
  modify $ \s -> s
    { builderBlock = emptyPartialBlock "entry"
    , builderBlocks = mempty
    , builderSupply = 0
    }
  let
    params = [LocalReference ty nm | (ty, nm) <- argtys]
  body params
  blocks <- gets builderBlocks
  modify $ \s -> s
    { builderBlock = startBlock
    , builderBlocks = startBlocks
    , builderSupply = startSupply
    }
  let
    def = GlobalDefinition $ functionDefaults {
      name        = label
    , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
    , returnType  = retty
    , basicBlocks = getSnocList blocks
    }
    funty = FunctionType retty (fst <$> argtys) False
  emitDefn def
  pure $ ConstantOperand $ globalRef funty label

-- Local reference
localRef ::  Type -> Name -> Operand
localRef = LocalReference

-- | Global reference
globalRef :: Type -> Name -> C.Constant
globalRef = C.GlobalReference

-------------------------------------------------------------------------------
-- Instructions
-------------------------------------------------------------------------------

fadd :: Operand -> Operand -> IRBuilder Operand
fadd a b = emitInstr (typeOf a) $ FAdd NoFastMathFlags a b []

fmul :: Operand -> Operand -> IRBuilder Operand
fmul a b = emitInstr (typeOf a) $ FMul NoFastMathFlags a b []

fsub :: Operand -> Operand -> IRBuilder Operand
fsub a b = emitInstr (typeOf a) $ FSub NoFastMathFlags a b []

fdiv :: Operand -> Operand -> IRBuilder Operand
fdiv a b = emitInstr (typeOf a) $ FDiv NoFastMathFlags a b []

frem :: Operand -> Operand -> IRBuilder Operand
frem a b = emitInstr (typeOf a) $ FRem NoFastMathFlags a b []

add :: Operand -> Operand -> IRBuilder Operand
add a b = emitInstr (typeOf a) $ Add False False a b []

mul :: Operand -> Operand -> IRBuilder Operand
mul a b = emitInstr (typeOf a) $ Mul False False a b []

sub :: Operand -> Operand -> IRBuilder Operand
sub a b = emitInstr (typeOf a) $ Sub False False a b []

udiv :: Operand -> Operand -> IRBuilder Operand
udiv a b = emitInstr (typeOf a) $ UDiv True a b []

sdiv :: Operand -> Operand -> IRBuilder Operand
sdiv a b = emitInstr (typeOf a) $ SDiv True a b []

urem :: Operand -> Operand -> IRBuilder Operand
urem a b = emitInstr (typeOf a) $ URem a b []

shl :: Operand -> Operand -> IRBuilder Operand
shl a b = emitInstr (typeOf a) $ Shl False False a b []

lshr :: Operand -> Operand -> IRBuilder Operand
lshr a b = emitInstr (typeOf a) $ LShr True a b []

ashr :: Operand -> Operand -> IRBuilder Operand
ashr a b = emitInstr (typeOf a) $ AShr True a b []

and :: Operand -> Operand -> IRBuilder Operand
and a b = emitInstr (typeOf a) $ And a b []

or :: Operand -> Operand -> IRBuilder Operand
or a b = emitInstr (typeOf a) $ Or a b []

xor :: Operand -> Operand -> IRBuilder Operand
xor a b = emitInstr (typeOf a) $ Xor a b []

alloca :: Type -> Maybe Operand -> Word32 -> IRBuilder Operand
alloca ty count align = emitInstr (ptr ty) $ Alloca ty count align []

load :: Operand -> Word32 -> IRBuilder Operand
load a align = emitInstr (typeOf a) $ Load False a Nothing align []

store :: Operand -> Word32 -> Operand -> IRBuilder Operand
store addr align val = emitInstr (typeOf val) $ Store False addr val Nothing align []

gep :: Operand -> [Operand] -> IRBuilder Operand
gep addr is = emitInstr (gepType (typeOf addr) is) (GetElementPtr False addr is [])

-- TODO: Perhaps use the function from llvm-hs-pretty (https://github.com/llvm-hs/llvm-hs-pretty/blob/master/src/LLVM/Typed.hs)
gepType :: Type -> [Operand] -> Type
gepType ty [] = ptr ty
gepType (PointerType ty _) (_:is) = gepType ty is
gepType (StructureType _ elTys) (ConstantOperand (C.Int 32 val):is) =
  gepType (elTys !! fromIntegral val) is
gepType (StructureType _ _) (i:_) = error $ "gep: Indices into structures should be 32-bit constants. " ++ show i
gepType (VectorType _ elTy) (_:is) = gepType elTy is
gepType (ArrayType _ elTy) (_:is) = gepType elTy is
gepType t (_:_) = error $ "gep: Can't index into a " ++ show t

trunc :: Operand -> Type -> IRBuilder Operand
trunc a to = emitInstr to $ Trunc a to []

zext :: Operand -> Type -> IRBuilder Operand
zext a to = emitInstr to $ ZExt a to []

sext :: Operand -> Type -> IRBuilder Operand
sext a to = emitInstr to $ SExt a to []

fptoui :: Operand -> Type -> IRBuilder Operand
fptoui a to = emitInstr to $ FPToUI a to []

fptosi :: Operand -> Type -> IRBuilder Operand
fptosi a to = emitInstr to $ FPToSI a to []

uitofp :: Operand -> Type -> IRBuilder Operand
uitofp a to = emitInstr to $ UIToFP a to []

sitofp :: Operand -> Type -> IRBuilder Operand
sitofp a to = emitInstr to $ SIToFP a to []

ptrtoint :: Operand -> Type -> IRBuilder Operand
ptrtoint a to = emitInstr to $ PtrToInt a to []

inttoptr :: Operand -> Type -> IRBuilder Operand
inttoptr a to = emitInstr to $ IntToPtr a to []

bitcast :: Operand -> Type -> IRBuilder Operand
bitcast a to = emitInstr to $ BitCast a to []

icmp :: IP.IntegerPredicate -> Operand -> Operand -> IRBuilder Operand
icmp pred a b = emitInstr i1 $ ICmp pred a b []

fcmp :: FP.FloatingPointPredicate -> Operand -> Operand -> IRBuilder Operand
fcmp pred a b = emitInstr i1 $ FCmp pred a b []

-- | Unconditional Branch
br :: Name -> IRBuilder ()
br val = emitTerm (Br val [])

-- | Phi
phi :: [(Operand, Name)] -> IRBuilder Operand
phi [] = emitInstr AST.void $ Phi AST.void [] []
phi incoming@(i:is) = emitInstr ty $ Phi ty incoming []
  where
    ty = typeOf (fst i) -- result type

-- | RetVoid
retVoid :: IRBuilder ()
retVoid = emitTerm (Ret Nothing [])

call :: Operand -> [(Operand, [ParameterAttribute])] -> IRBuilder Operand
call fun args = do
  let retty = case typeOf fun of
        FunctionType r _ _ -> r
        _ -> VoidType -- XXX: or error?
  emitInstr retty Call {
    AST.tailCallKind = Nothing
  , AST.callingConvention = CC.C
  , AST.returnAttributes = []
  , AST.function = Right fun
  , AST.arguments = args
  , AST.functionAttributes = []
  , AST.metadata = []
  }

-- | Ret
ret :: Operand -> IRBuilder ()
ret val = emitTerm (Ret (Just val) [])

switch :: Operand -> Name -> [(C.Constant, Name)] -> IRBuilder ()
switch val def dests = emitTerm $ Switch val def dests []

select :: Operand -> Operand -> Operand -> IRBuilder Operand
select cond t f = emitInstr (typeOf t) $ Select cond t f []

condBr :: Operand -> Name -> Name -> IRBuilder ()
condBr cond tdest fdest = emitTerm $ CondBr cond tdest fdest []

-- | Constant
cons :: C.Constant -> Operand
cons = ConstantOperand

-------------------------------------------------------------------------------
-- Testing
-------------------------------------------------------------------------------

c1 :: Operand
c1 = cons $ C.Float (F.Double 10)

c2 :: Operand
c2 = cons $ C.Int 32 10


example :: IO ()
example = T.putStrLn $ ppllvm $ mkModule $ runIRBuilder emptyIRBuilder $ mdo

  foo <- function "foo" [] double $ \_ -> mdo

    blk1 <- block "b1"; do
      a <- fadd c1 c1
      b <- fadd a a
      c <- add c2 c2
      br blk2

    blk2 <- block "b2"; do
      a <- fadd c1 c1
      b <- fadd a a
      c <- call foo []
      br blk3

    blk3 <- block "b3"; do
      l <- phi [(c1, blk1), (c1, blk2), (c1, blk3)]
      a <- fadd c1 c1
      b <- fadd a a
      retVoid

    pure ()


  function "bar" [] double $ \_ -> mdo

    blk3 <- block "b3"; do
      a <- fadd c1 c1
      b <- fadd a a
      retVoid

    pure ()

  function "baz" [(double, "arg")] double $ \[arg] -> mdo

    switch c2 blk1 [(C.Int 32 0, blk2), (C.Int 32 1, blk3)]

    blk1 <- block "b1"; do
      br blk2

    blk2 <- block "b2"; do
      a <- fadd arg c1
      b <- fadd a a
      select (cons $ C.Int 1 0) a b
      retVoid

    blk3 <- block "b3"; do
      let nul = cons $ C.Null $ ptr $ ptr $ ptr $ IntegerType 32
      addr <- gep nul [cons $ C.Int 32 10, cons $ C.Int 32 20, cons $ C.Int 32 30]
      addr <- gep addr [cons $ C.Int 32 40]
      retVoid

    pure ()
  where
    mkModule ds = (emptyModule "exampleModule") { moduleDefinitions = ds }
