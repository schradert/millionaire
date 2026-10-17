;;; helix-layer.el --- a few helix keys on top of Doom evil + SPC leader

;; Research (2026-10-16): no maintained package layers helix editing ON evil.
;; `evil-helix' is a Rust fork of the Helix editor, not Emacs. `helix-mode'
;; (mgmarlow, MELPA) and anuvyklack's selection-first package (MELPA) are standalone modal
;; systems (per their READMEs neither builds on evil; maintenance dates not checked); `meow' is a modal framework with its own keypad that Doom
;; can host only through a community module, losing evil-collection and Doom's
;; `map!' leader. So: evil is the base (Doom `:editor (evil +everywhere)', SPC
;; leader untouched) and this file only ADDS the helix selection-first keys
;; that evil lacks. Evil's own i/a text objects, `gc' comment operator, surround
;; (`ys'/`cs'/`ds', visual `S') and `U' redo already cover most of the rest.
;;
;; Mapping from helix (kept to what does not take away an evil habit):
;;   x     select line, again = extend by a line      (loses evil `x' delete-char)
;;   X     select line bounds                         (loses evil `X' delete-back)
;;   ;     visual only: collapse selection            (normal `;' stays repeat-find)
;;   gh    line start     gl  line end     gs  first non-blank (loses doom `gs' easymotion; evil-lion's
;;         left align `gl' moves to gA, gL stays; org buffers keep evil-org's gh/gj/gk/gl)
;;   U     redo
;;   g.    last change (evil `g;' already does this)
;;   C / M-C  visual only: add cursor below / above (evil-mc); normal `C' stays change-to-eol
;; Not mapped on purpose: `ge' (evil: backward word end; `G' goes to buffer end),
;; `C-c' comment (C-c is a prefix; use `gcc'/`gc'), `m' prefix (evil marks; use
;; `vi(' / `va(' for match inside/around), `%' select-all (evil: matching paren),
;; `_' trim selection (no clean equivalent).

(defun my/helix-select-line ()
  "Helix `x': select the current line; when a selection exists, extend it by a line."
  (interactive)
  (cond ((not (evil-visual-state-p)) (evil-visual-line))
        ((eq (evil-visual-type) 'line) (evil-next-line 1))
        (t (evil-visual-line))))

(defun my/helix-line-bounds ()
  "Helix `X': extend the selection to whole lines."
  (interactive)
  (if (evil-visual-state-p) (evil-visual-line) (my/helix-select-line)))

;; helix-layer
(map! :nv "x" #'my/helix-select-line      ; select / extend line (replaces delete-char)
      :nv "X" #'my/helix-line-bounds      ; select line bounds (replaces delete-backward-char)
      :v  ";" #'evil-exit-visual-state    ; collapse selection to point
      :mnv "gh" #'evil-beginning-of-line  ; line start
      :mnv "gl" #'evil-end-of-line        ; line end (replaces doom evil-lion gl; its left align is gA)
      :nv  "gA" #'evil-lion-left          ; evil-lion left align, moved off gl
      :mnv "gs" #'evil-first-non-blank    ; first non-blank (replaces doom easymotion gs)
      :n  "U" #'evil-redo                 ; redo
      :m  "g." #'goto-last-change         ; last modification (same as evil g;)
      :v  "C" #'evil-mc-make-cursor-move-next-line  ; cursor below (evil-mc)
      :v  "M-C" #'evil-mc-make-cursor-move-prev-line) ; cursor above (evil-mc)
