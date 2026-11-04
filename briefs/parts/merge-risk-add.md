   - Add the subagent's `{{OUT}}/merge-risk.json` as `merge_risk`, as
     written. Correct a gap only when it's factually wrong, such as "no test
     covers X" when one does, and note the correction in `checker.md`.
     Merge risk never changes the event: blocking still needs a concrete
     failure. If the subagent failed, assess merge risk yourself and say so
     in `checker.md`. {{MERGE_RISK_GUIDE}}
