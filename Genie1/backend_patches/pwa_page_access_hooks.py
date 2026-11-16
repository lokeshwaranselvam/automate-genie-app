"""Merge these entries into apps/itgenie/itgenie/hooks.py.

This is a hook snippet, not a replacement for your existing hooks.py.
If either list already exists, append its new entry to the existing list.
"""

before_request = [
    "itgenie.pwa_page_access.before_request",
]

after_request = [
    "itgenie.pwa_page_access.after_request",
]
