# Org settings shared by the places that must agree: Emacs (modules/emacs/default.nix) and the
# org-bridge worker that exports headings to CalDAV (nixidy/apps/home/org-bridge.nix).
{
  # `org-todo-keywords` order: active states, `|`, done states. Fast keys (`PLANNED(p!)`) are for
  # Emacs and ignored by org-bridge.
  todoKeywords = "DRAFTING(d@) PLANNED(p!) IN-PROGRESS(i!/@) WAITING(w@) | COMPLETED(c@) REJECTED(r@) MISSED(m@)";
}
