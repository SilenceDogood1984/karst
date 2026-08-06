# Karst

Karst is a runtime evidence engine for Rails.

## What is Karst?

Karst is intended to capture what actually happened while a Rails application ran and make that evidence useful. It starts from observed behavior rather than guesses about what code might do.

## Philosophy

- Prefer runtime observation to static inference.
- Require evidence for every claim.
- Prefer silence to false certainty.
- Make every recommendation traceable to captured evidence.
- Favor small, composable primitives.

Observation comes before recommendation.

## Why runtime evidence?

Static analysis can describe possible behavior. Runtime evidence describes behavior that occurred in a particular execution. Karst will preserve that distinction so developers can evaluate findings in their real application context.

## Current capabilities

Karst is being bootstrapped. It does not capture or analyze runtime behavior yet.

## Roadmap

Development will proceed from small evidence-capture primitives to traceable analysis and, only where the evidence supports it, recommendations. Concrete capabilities will be documented as they are designed and shipped.

## Installation

Coming soon. Karst is not yet published for use in Rails applications.

## Contributing

Contributions and design discussion are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and the evidence expected in a change.
