# Operations

Tune `mail.retry_limit` and `mail.retry_backoff_ms` together when the
provider throttles. `queue.poll_interval_ms` controls consumer latency.
`cache.warm_keys` is a comma-separated list applied at boot.
