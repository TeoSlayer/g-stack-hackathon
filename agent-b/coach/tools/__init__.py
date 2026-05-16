"""Coach tool surface: thin shells around external CLIs.

These are intentionally subprocess-based: gbrain, pilotctl, gstack, and
others have stable CLIs and richer feature sets than any Python binding
we'd write. Treating them as tools keeps the Coach focused on composing
queries and reasoning over results.
"""
