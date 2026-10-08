# Count contractions and compounds as one word

Word statistics split `don't` into `don` and `t`, and `well-known` into two
words. Writers want them counted as single words.

- `stats.word_count`, `stats.unique_count` and `stats.top_words` treat a
  contraction (`don't`, `it's`) and a hyphenated compound (`well-known`,
  `state-of-the-art`, `covid-19`) as one word.
- A typographic apostrophe (`’`) counts as `'`; words are reported with `'`.
- Apostrophes and hyphens only join letters or digits on both sides. A leading
  or trailing one is not part of the word (`'tis` → `tis`, `rock-` → `rock`),
  and a doubled one separates words (`yes--no` is two words).
- Words stay lowercase.
- Search is unchanged: searching `known` still finds a document containing
  `well-known`, and searching `don` still finds one containing `don't`.
