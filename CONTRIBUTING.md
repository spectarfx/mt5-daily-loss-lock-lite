# Contributing

Thank you for taking the time.

- **Bugs:** open an issue with your MetaTrader 5 build, account type (hedging or netting), the inputs you used and the lines from the Experts tab of the terminal.
- **Pull requests:** keep them small and focused. The EA must stay a single `.mq5` file with no DLLs, no web requests and no hard-coded symbols. Please compile with 0 errors and 0 warnings and describe how you tested it (Strategy Tester or a demo account).
- **Scope:** this project does one thing, the daily loss lock. Features that open or manage trades are out of scope.
- **Security:** if you find something that could make the lock fail silently, write to support@spectarfx.com rather than opening a public issue.

By contributing you agree that your contribution is licensed under the MIT License of this repository.
