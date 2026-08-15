# PLACEHOLDER — this is not your Terms of Service

**Replace this entire file before you present it to anyone.**

The `clickwrap` gem generated this placeholder so that `config/clickwrap.rb` has
a file to point at and `bin/rails clickwrap:publish` has bytes to digest. It is
not terms. It is not a draft of terms. It is not a starting point for terms.

Clickwrap deliberately never writes legal text. It has no idea who you are, what
you sell, where you operate, who your users are, or which rules apply to any of
that — and text that merely *looked* plausible would be worse than this file,
because someone would ship it.

What the gem does own is the mechanics around whatever you put here: the exact
bytes and their digest, the version and locale, the wording and call to action
in the server-generated offer, the submitted answer, the time your server
recorded it, and a receipt that can be reproduced and verified years later.
What the words say, whether they are fair, whether they are complete, and
whether they do what you need them to do is yours and your counsel's.

## What to do now

1. Replace this file with your own reviewed Terms of Service.
2. Set the matching `version:` label in `config/clickwrap.rb`. A label is yours
   to choose; reusing one for different bytes is refused rather than accepted.
3. Run `bin/rails clickwrap:publish` to freeze an immutable snapshot.
4. Publish a NEW version whenever the text changes. Published bytes are never
   edited in place — that is what lets a receipt from three years ago reproduce
   the exact document version its accepted server offer bound.

If this text ever reaches a real person, something went wrong: check that this
file was replaced, and that `clickwrap:publish` ran against the replacement.
