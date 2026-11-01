# Maintaining these instructions

- When you notice recurring feedback or a new convention that isn't captured yet, proactively propose adding it as a rule — surface it as a suggested edit for the user to approve rather than editing on your own initiative. General Swift style, code organization and structure rules go to the shared user-level rule `~/.claude/rules/swift-style.md` (loaded automatically for Swift files in scout, scout-db, scout-server and scout-ip); only scout-db-specific conventions go here.

# Initializer assignments

- In an initializer, if at least one property assignment needs `self.` (a parameter or local shadows the property), prefix every property assignment with `self.` for consistency; if none needs it, omit `self.` from all of them.
