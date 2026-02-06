# Contributing to Azure Local LENS Workbook

Thank you for your interest in contributing to the Azure Local LENS (Lifecycle, Events & Notification Status) Workbook! This is a community-driven, open-source project and we welcome contributions from the community.

> **Note:** This project is not officially supported by Microsoft. No time scales or guarantees can be provided for responses to issues or pull requests.

## How to Contribute

### Reporting Issues (Recommended)

**We highly recommend raising an issue rather than submitting a pull request.** The workbook JSON is complex and changes can have unintended side effects across multiple tabs and queries. By raising an issue, the maintainers can assess the impact, implement the change with full context, and ensure proper testing.

If you find a bug, have a feature request, or want to provide feedback:

1. Check [existing issues](https://github.com/Azure/AzureLocal-LENS-Workbook/issues) to avoid duplicates
2. [Open a new issue](https://aka.ms/AzureLocalLENS/issues) with a clear description
3. Include relevant details such as:
   - Steps to reproduce (for bugs)
   - Expected vs actual behaviour
   - Screenshots where applicable
   - The workbook version you are using (shown in the version banner)

### Submitting Pull Requests

> **⚠️ Please raise an issue first** before opening a PR. This allows maintainers to discuss the approach and avoid duplicate or conflicting work. Unsolicited PRs without a corresponding issue may not be reviewed.

If you have been asked to submit a PR, or have discussed the change in an issue:

1. **Fork** the repository
2. **Create a feature branch** from `main` (e.g., `users/yourname/fix-description`)
3. **Make your changes** — see [Development Guidelines](#development-guidelines) below
4. **Run the tests** to ensure nothing is broken:
   ```bash
   node scripts/run-tests.js
   ```
5. **Commit** with a clear, descriptive message
6. **Open a Pull Request** against `main`

## Development Guidelines

### Repository Structure

| File/Folder | Purpose |
|---|---|
| `AzureLocal-LENS-Workbook.json` | The main Azure Monitor Workbook template (single JSON file) |
| `README.md` | Documentation, import instructions, and version changelog |
| `scripts/run-tests.js` | Unit tests validating workbook structure and consistency |
| `.github/workflows/test.yml` | CI/CD pipeline that runs tests on push/PR to `main` |

### Working with the Workbook JSON

The workbook is a single JSON file following the Azure Monitor Workbook `Notebook/1.0` format. When making changes:

- **KQL Queries**: Queries are embedded as escaped strings within JSON. Use `\r\n` for line breaks and be careful with quote escaping
- **Version**: Update the version in both the JSON version banner (`version-update-banner` item) and [README.md](README.md) header
- **Item Names**: Give all items a descriptive `name` property for maintainability
- **Row Limits**: Set `rowLimit` to at least `2000` in grid settings
- **Cross-Component Resources**: Use `{Subscriptions}` for `crossComponentResources` to respect the user's subscription filter

### KQL Query Best Practices

- Always include the `ResourceGroupFilter` wildcard check for consistent filtering
- Include the `ClusterTagName`/`ClusterTagValue` filter where applicable
- Use `extensibilityresources` for Azure Local HCI resource types
- Be mindful of Azure Resource Graph join constraints in workbooks (max one right join per query)
- Test queries in [Azure Resource Graph Explorer](https://portal.azure.com/#view/HubsExtension/ArgQueryBlade) before embedding

### Version Bumping

When preparing a release:

1. Update the version in the workbook JSON banner (`Workbook Version: vX.Y.Z`)
2. Update `## Latest Version: vX.Y.Z` in README.md
3. Update `## Recent Changes (vX.Y.Z)` in README.md with your changelog
4. Move the previous version's changes to the `## Appendix: Previous Version Changes` section

### Running Tests

The project uses a zero-dependency Node.js test runner that validates:

- JSON structure and schema compliance
- KQL query syntax basics (balanced quotes, pipe operators, etc.)
- Chart configuration (axis settings, visualization types)
- Version consistency between JSON and README
- Parameter definitions and cross-component resources
- File size and performance checks

```bash
# Run all tests (produces NUnit XML in test-results/)
node scripts/run-tests.js
```

All 50 tests must pass before a PR can be merged. The CI pipeline runs these automatically on every push and PR to `main`.

## Code of Conduct

This project follows the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com).

## Security

For security concerns, please refer to [SECURITY.md](SECURITY.md). **Do not report security vulnerabilities through public GitHub issues.**

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
