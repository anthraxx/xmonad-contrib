{-# LANGUAGE PatternGuards, FlexibleInstances, MultiParamTypeClasses #-}
{-# OPTIONS -fglasgow-exts #-}
-- deriving Typeable
-----------------------------------------------------------------------------
-- |
-- Module       : XMonad.Hooks.ManageDocks
-- Copyright    : (c) Joachim Breitner <mail@joachim-breitner.de>
-- License      : BSD
--
-- Maintainer   : Joachim Breitner <mail@joachim-breitner.de>
-- Stability    : unstable
-- Portability  : unportable
--
-- This module provides tools to automatically manage 'dock' type programs,
-- such as gnome-panel, kicker, dzen, and xmobar.

module XMonad.Hooks.ManageDocks (
    -- * Usage
    -- $usage
    manageDocks, AvoidStruts, avoidStruts, ToggleStruts(ToggleStruts)
    ) where


-----------------------------------------------------------------------------
import XMonad
import Foreign.C.Types (CLong)
-- import Data.Maybe (catMaybes, fromMaybe)
import Control.Monad

-- $usage
-- To use this module, add the following import to @~\/.xmonad\/xmonad.hs@:
--
-- > import XMonad.Hooks.ManageDocks
--
-- The first component is a 'ManageHook' which recognizes these windows.  To
-- enable it:
--
-- > manageHook = ... <+> manageDocks
--
-- The second component is a layout modifier that prevents windows from
-- overlapping these dock windows.  It is intended to replace xmonad's
-- so-called "gap" support.  First, you must add it to your list of layouts:
--
-- > layoutHook = avoidStruts (tall ||| mirror tall ||| ...)
-- >                   where  tall = Tall 1 (3/100) (1/2)
--
-- 'AvoidStruts' also supports toggling the dock gap, add a keybinding similar
-- to:
--
-- > ,((modMask x, xK_b     ), sendMessage ToggleStruts)
--
-- For detailed instructions on editing your key bindings, see
-- "XMonad.Doc.Extending#Editing_key_bindings".

-- |
-- Detects if the given window is of type DOCK and if so, reveals it, but does
-- not manage it. If the window has the STRUT property set, adjust the gap accordingly.
manageDocks :: ManageHook
manageDocks = checkDock --> doIgnore

-- |
-- Checks if a window is a DOCK or DESKTOP window
checkDock :: Query Bool
checkDock = ask >>= \w -> liftX $ do
    a <- getAtom "_NET_WM_WINDOW_TYPE"
    dock <- getAtom "_NET_WM_WINDOW_TYPE_DOCK"
    desk <- getAtom "_NET_WM_WINDOW_TYPE_DESKTOP"
    mbr <- getProp a w
    case mbr of
        Just [r] -> return $ elem (fromIntegral r) [dock, desk]
        _        -> return False

-- |
-- Gets the STRUT config, if present, in xmonad gap order
getStrut :: Window -> X [Strut]
getStrut w = do
    spa <- getAtom "_NET_WM_STRUT_PARTIAL"
    sa  <- getAtom "_NET_WM_STRUT"
    msp <- getProp spa w
    case msp of
        Just sp -> return $ parseStrutPartial sp
        Nothing -> fmap (maybe [] parseStrut) $ getProp sa w
 where
    parseStrut xs@[_, _, _, _] = parseStrutPartial . take 12 $ xs ++ cycle [minBound, maxBound]
    parseStrut _ = []

    parseStrutPartial [l, r, t, b, ly1, ly2, ry1, ry2, tx1, tx2, bx1, bx2]
     = filter (\(_, n, _, _) -> n /= 0)
        [(L, l, ly1, ly2), (R, r, ry1, ry2), (T, t, tx1, tx2), (B, b, bx1, bx2)]
    parseStrutPartial _ = []

-- |
-- Helper to read a property
getProp :: Atom -> Window -> X (Maybe [CLong])
getProp a w = withDisplay $ \dpy -> io $ getWindowProperty32 dpy a w

-- |
-- Goes through the list of windows and find the gap so that all STRUT
-- settings are satisfied.
calcGap :: X (Rectangle -> Rectangle)
calcGap = withDisplay $ \dpy -> do
    rootw <- asks theRoot
    -- We don't keep track of dock like windows, so we find all of them here
    (_,_,wins) <- io $ queryTree dpy rootw
    struts <- concat `fmap` mapM getStrut wins

    -- we grab the window attributes of the root window rather than checking
    -- the width of the screen because xlib caches this info and it tends to
    -- be incorrect after RAndR
    wa <- io $ getWindowAttributes dpy rootw
    let screen = r2c $ Rectangle (fi $ wa_x wa) (fi $ wa_y wa) (fi $ wa_width wa) (fi $ wa_height wa)
    return $ \r -> c2r $ foldr (reduce screen) (r2c r) struts

fi :: (Integral a, Num b) => a -> b
fi = fromIntegral

r2c :: Rectangle -> RectC
r2c (Rectangle x y w h) = (fi x, fi y, fi x + fi w, fi y + fi h)

c2r :: RectC -> Rectangle
c2r (x1, y1, x2, y2) = Rectangle (fi x1) (fi y1) (fi $ x2 - x1) (fi $ y2 - y1)

-- | Adjust layout automagically.
avoidStruts :: LayoutClass l a => l a -> AvoidStruts l a
avoidStruts = AvoidStruts True

data AvoidStruts l a = AvoidStruts Bool (l a) deriving ( Read, Show )

data ToggleStruts = ToggleStruts deriving (Read,Show,Typeable)
instance Message ToggleStruts

instance LayoutClass l a => LayoutClass (AvoidStruts l) a where
    doLayout (AvoidStruts True lo) r s =
        do rect <- fmap ($ r) calcGap
           (wrs,mlo') <- doLayout lo rect s
           return (wrs, AvoidStruts True `fmap` mlo')
    doLayout (AvoidStruts False lo) r s = do (wrs,mlo') <- doLayout lo r s
                                             return (wrs, AvoidStruts False `fmap` mlo')
    handleMessage (AvoidStruts b l) m
        | Just ToggleStruts <- fromMessage m = return $ Just $ AvoidStruts (not b) l
        | otherwise = do ml' <- handleMessage l m
                         return (AvoidStruts b `fmap` ml')
    description (AvoidStruts _ l) = description l

    emptyLayout (AvoidStruts b l) r = do (wrs,ml) <- emptyLayout l r
                                         return (wrs, AvoidStruts b `fmap` ml)

data Side = L | R | T | B

type Strut = (Side, CLong, CLong, CLong)

type RectC = (CLong, CLong, CLong, CLong)

reduce :: RectC -> Strut -> RectC -> RectC
reduce (sx0, sy0, sx1, sy1) (s, n, l, h) (x0, y0, x1, y1) = case s of
    L | p (y0, y1) -> (mx x0 sx0    , y0       , x1       , y1       )
    R | p (y0, y1) -> (x0           , y0       , mn x1 sx1, y1       )
    T | p (x0, x1) -> (x0           , mx y0 sy0, x1       , y1       )
    B | p (x0, x1) -> (x0           , y0       , x1       , mn y1 sy1)
    _              -> (x0           , y0       , x1       , y1       )
 where
    mx a b = max a (b + n)
    mn a b = min a (b - n)
    inRange (a, b) c = c > a && c < b
    p (a, b) = inRange (a, b) l || inRange (a, b) h || inRange (a, b) l || inRange (l, h) b