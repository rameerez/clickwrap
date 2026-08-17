# Accessibility: what the reference views do, and what stays yours

Clickwrap ships tested reference views. They are a good starting point and they are one
fragment of one page. **Nothing in this gem certifies your application under
[WCAG 2.2](https://www.w3.org/TR/WCAG22/) *(technical standard)* or any other accessibility
standard**, and no library that sees a single partial could. Accessibility applies to the whole
experience: placement, contrast, clutter, reading order, focus management across the page,
error recovery, and whether the surrounding design lets somebody find the control at all.

What follows is the exact division of responsibility, so your review can spend its time on the
part that is actually yours.

---

## What the reference views do

All of this is in `app/views/clickwrap/shared/_fields.html.erb`,
`_statement.html.erb`, and `_error_summary.html.erb`, and is exercised by
the gem's own suite.

### Labels and programmatic names

Every control has one label, tied together by ID, and the label carries the words:

```erb
<%= check_box_tag combined.control_name, "1", false, id: combined.control_id, ... %>
<%= label_tag combined.control_id, clickwrap_combined_sentence(combined) %>
```

The label **is** the sentence — including the document links, which sit inside it. Pressing the
words toggles the control, and assistive technology announces the sentence and the box together.
There is no `aria-label` standing in for a visible label, and no placeholder doing a label's job.

For an explicit yes/no decision, the group is a real `<fieldset>` with a `<legend>` carrying the
assertion, and each radio has its own `<label>`.

### The default is one line

An ordinary signup renders one checkbox carrying one sentence:

> ☐ I agree to the [Terms of Service](#) and I acknowledge the [Privacy Policy](#).

That is a deliberate accessibility decision as much as a visual one. Two boxes, two "Required"
flags, two version labels, and four stacked links are four times the interface for the same
decision — and everything a screen-reader user has to hear before reaching the button is
something a sighted user gets to skip.

### One control never covers two *different kinds of* answer

The composed line is one control answering several statements, and it is allowed to be, because
the server signs which statements it covered and answers all of them from the one box. What it
may never absorb is an answer somebody could reasonably want to give differently: an optional
consent (which the line would silently make required), a recorded yes/no, a purpose with a
withdrawal route, or copy the application wrote itself. Each of those keeps its own control below
the line — and the development linter flags
`combined_statement_rendered_as_its_own_control` if a page offers a *second* control for a
statement the signed line already covers, because that box offers a choice nobody has.

### Controls start unselected

There is no `checked` attribute anywhere in the statement partial, and there never will be. A
pre-ticked box records the page's default rather than a person's action. The development linter
flags `consent_control_preselected` if it finds one in rendered output.

### Focus is visible and keyboard operation works

The shipped stylesheet defines a visible focus indicator rather than removing the browser's.
Every control is a native input; nothing is a `div` with a click handler. Tab order is document
order because the markup is in reading order.

### Error relationships are programmatic

When a statement fails validation, its control gets `aria-invalid="true"` and
`aria-describedby` pointing at the paragraph carrying the message. The paragraph has the
matching `id`. The `fieldset` gets the same treatment for choice groups.

### There is an error summary, and it takes focus

```erb
<div class="clickwrap-error-summary" role="alert" tabindex="-1" autofocus>
```

`role="alert"` so assistive technology announces it when the failed submission re-renders,
`tabindex="-1"` so it can hold focus, and `autofocus` so the browser moves focus there on load —
**without a line of JavaScript**. Each entry is a link to the control it is about, so the fix is
one press away rather than a scroll and a hunt. One control gets one entry however many acts it
answered: three lines pointing at the same checkbox is a list of the page's internals, not of a
person's problems.

### Meaning is never carried by color alone

Error messages carry a text prefix (`clickwrap.ui.error_prefix`) before the message. The styling
underlines and colors these; the meaning survives without either.

Nothing prints the word "Required" beside a control. The `required` attribute is there as
progressive enhancement, and **the server decides** either way — but a required control on a
signup form is not information anybody is missing, and a page that has to say it is a page
expecting to be argued with. An optional consent stays unlabelled for the same reason and
because it is unticked, unrequired, and separate: three signals that say it already.

### It works with no JavaScript

No Stimulus controller is required for correctness. Validation, error rendering, focus on the
summary, and evidence capture all work in a browser that never runs a script. HTML `required`
is progressive enhancement only — **the server decides**, and a client that ignores the
attribute, never sends the field, or posts by hand meets the same server-side check.

### Document links come before the action

Links to each document render above the submit control — inside the sentence on the composed
line, under the statement on an itemized one — carry the document's own name rather than "click
here", and open in a new tab with `rel="noopener"` so a half-filled form is not lost. A link
that only appears after the call to action has been pressed is not a link to anything.

The "opens in a new tab" hint is rendered as an `sr-only` span rather than visible text: a
sighted person gets their browser's own new-tab behavior and does not need it spelled out beside
every link, and a screen-reader user gets the words. It is still rendered **only** when the link
really does open a new tab, so hosts that change how links open —
`config.document_link_html_options_with`, or `config.hotwire_native_document_links` for a native
app — change the hint with them, and a `:same_screen` native link announces nothing it does not
do.

There is no version label beside a control. Versions are on the receipt, where somebody is
reading the record and can act on them.

### Locale-aware selection, with no silent fallback

Human-facing text resolves to the requested locale before presentation, and a missing required
translation fails closed rather than rendering a raw I18n key, a blank, or an unexpected
language.

---

## What the host still owns

Everything below is outside what the gem can see, and all of it can defeat a correct partial.

| Yours | Why it matters |
|---|---|
| **Placement on the page** | A conspicuous control in a cluttered layout is not conspicuous. Where the block sits relative to the rest of the form is a design decision Clickwrap cannot make |
| **Contrast and type size** | The reference stylesheet is a starting point in your color system, not a contrast audit of it. Check the rendered values against your own palette |
| **The call-to-action wording** | You pass `submit:`. Whether that text tells the person what pressing it does is your judgment |
| **Reading order of the whole page** | The partial is in order internally. Whether the surrounding markup keeps it that way is not something a partial can control |
| **Page-level focus management** | The error summary takes focus on re-render. If your framework, modal, or Turbo Frame moves focus afterwards, that is yours to reconcile |
| **Zoom, reflow, and small viewports** | Test at 200% and 400%, and at 320 CSS pixels wide |
| **Motion, timeouts, and interruptions** | Presentation tokens are short-lived by default (`config.presentation_valid_for`, two hours). If a person needs longer than your timeout allows, that is your flow to fix |
| **The document itself** | Whether the Terms, notice, or declaration is readable — plain language, headings, structure — is content, and content is yours |
| **Native and API surfaces** | Hotwire Native web screens use the same component; a fully custom native or JSON presentation renders your own controls against the presenter's primitives, and inherits none of the above |
| **Ejected views** | `bin/rails generate clickwrap:views` copies these partials into your app, where they shadow the gem's. From that moment every property above is yours to keep |
| **Assistive-technology testing with real users** | No automated check substitutes for it |

---

## The linter is a heuristic, not a verdict

In development and test only, `Clickwrap::Linter` scans policies, manifests, and rendered
fragments for objectively checkable mistakes. It warns; it never raises, never blocks a render,
and never certifies anything. A clean run means "none of the specific hazards below were
detected in what was inspected," and nothing else.

| Finding | What it noticed |
|---|---|
| `submit_control_before_clickwrap_block` | A submit control appears above the statements it is supposed to accept |
| `consent_control_preselected` | A rendered control carries `checked` |
| `document_link_missing` | A statement cites a document that nothing links to |
| `assertion_text_blank` | A statement would render with no sentence |
| `consent_statement_bundles_purposes` | A consent assertion contains "and", "and/or", "as well as", or "plus" — probably two purposes in one control |
| `optional_consent_required_for_another_action` | An optional consent has been made mandatory in practice by another statement's `requires:` |
| `rendered_manifest_differs_from_policy` | What was rendered does not match what the policy declared |

Every finding carries a stable symbol so a test can assert on it without matching English, and a
full-sentence explanation so somebody reading the log knows what to do.

---

## Reviewer checklist

Run this against a real page in a real browser, not against the partial.

**Structure and naming**

- [ ] Every control has a visible label whose text is exactly what the server offered — the
      composed sentence, or the statement's own assertion. Pressing the label text toggles the
      control.
- [ ] No control covers a statement the signed presentation did not say it covers, and no
      statement the composed line covers has a second control of its own.
- [ ] Choice groups are a `fieldset` with a `legend`.
- [ ] Every control has an accessible name in the accessibility tree — check it, do not assume.

**State**

- [ ] Every control renders unselected on first load and after a failed submission.
- [ ] Nothing on your surrounding page conveys "required" by color or an asterisk alone.

**Keyboard and focus**

- [ ] Every control, link, and the submit button is reachable and operable by keyboard alone.
- [ ] The focus indicator is visible against your actual background, at every step.
- [ ] Tab order matches visual order across the whole form, not just the Clickwrap block.

**Errors**

- [ ] Submit with nothing selected. An error summary appears, receives focus, and each entry
      links to its control.
- [ ] Each failing control has `aria-invalid="true"` and `aria-describedby` pointing at a
      message that exists.
- [ ] Error text is readable with color disabled or in grayscale.

**Documents**

- [ ] Every document is linked, above the submit control, with the document's own name.
- [ ] The `sr-only` "opens in a new tab" hint is announced — check it in a screen reader, not
      only in the markup, and check that your own CSS has not turned `.clickwrap-sr-only` into
      `display: none`, which would remove it from the accessibility tree entirely.
- [ ] Following a link and returning does not lose the form state.

**Without JavaScript**

- [ ] Disable JavaScript. Render, fail validation, correct, and submit successfully.
- [ ] The error summary still receives focus.

**Page level**

- [ ] At 400% zoom and at 320 CSS pixels wide, nothing overlaps and nothing is cut off.
- [ ] Contrast of label text, link text, error text, and the focus indicator meets your target
      against your real palette.
- [ ] Screen-reader pass: the whole sentence, its document links, and any error are all
      announced, in an order that makes sense — and a link inside the sentence does not break
      the sentence into fragments that stop reading as one statement.
- [ ] The submit button's text says what pressing it does.

**Locale**

- [ ] Each supported locale renders, including the document links and version labels.
- [ ] A missing translation fails loudly in development rather than rendering a key.

None of the above certifies anything. It is the list of things that are cheap to check and
expensive to miss.

---

## Sources

| Source | Class |
|---|---|
| [WCAG 2.2](https://www.w3.org/TR/WCAG22/) | Technical standard |
| [15 U.S.C. § 7001(d)](https://www.law.cornell.edu/uscode/text/15/7001) — accurate reflection, accessibility, and reproducibility of electronic records | Law |
| [Berman v. Freedom Financial Network](https://cdn.ca9.uscourts.gov/datastore/opinions/2022/04/05/20-16900.pdf), [Toth v. Everly Well](https://www.ca1.uscourts.gov/sites/ca1/files/opnfiles/23-1727P-01A.pdf) — US appellate decisions assess conspicuous notice and unambiguous assent in the context of the whole interface; no control, color, or placement is a universal safe harbor | Cases |
| The division of responsibility and the checklist above | Product-design inference |
