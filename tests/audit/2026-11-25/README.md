# Audit reproduction probes

These probes assert that the audited defects **exist**. A passing result is not a security approval. After fixing each defect, invert the relevant assertion and add a normal regression test in its owned suite.

- `journal_probe.py`: run from the repository root with Python 3; temporary SQLite only.
- `gateway_probe.py`: mount into `/checks/probe.py` in the local gateway image and run `python /checks/probe.py`; synthetic client only, no Telegram network calls.
- `reproductions_spec.rb`: mount as `/app/spec/corporate/audit_spec.rb` into the `chatwoot-spec` service, with current app/lib/config/spec mounts, then `bundle exec rspec spec/corporate/audit_spec.rb`. The corporate helper refuses any database except `chatwoot_spec`.

Never run these probes against the company account or production data. The EICAR fixture is a harmless antivirus test signature, created in a temporary local file and never sent externally.
