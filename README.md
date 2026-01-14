# CBQ AutoBatch

Automatic job batching for ColdBox cbq. When a job exceeds a configurable item threshold, it automatically splits the workload into smaller parallel batches while preserving chained job execution.

## Installation

```bash
box install cbq-autobatch
```

## Requirements

- ColdBox 6+
- cbq 4+
- Lucee 5+ or Adobe ColdFusion 2018+

## Usage

### Basic Setup

Inject the AutoBatch service and configure via props:

```cfml
component extends="cbq.models.Jobs.AbstractJob" {

    property name="autoBatch" inject="AutoBatch@cbqAutoBatch";

    function handle() {
        var props = getProperties();

        // Batch configuration - all in props
        param props.autoBatch     = true;
        param props.batchSize     = 20;
        param props.batchItemsKey = "accounts";   // key containing struct to chunk
        param props.batchIdKey    = "accountIDs"; // key to populate with chunk keys

        // ... resolve your items ...
        props.accounts = loadAccounts();

        // Check for auto-batching - just pass this and props
        var result = autoBatch.evaluate( this, props );
        if ( result.batched ) {
            return result.result;
        }

        // Continue with single-job execution for items under threshold
        processItems( props.accounts );
    }

}
```

### Props Contract

All configuration lives in props (with sensible defaults):

| Prop | Default | Description |
|------|---------|-------------|
| `autoBatch` | `false` | Enable auto-batching |
| `batchSize` | `10` | Items per batch |
| `batchQueue` | `"default"` | Queue/connection for batch jobs |
| `batchItemsKey` | `"items"` | Key in props containing struct to chunk |
| `batchIdKey` | `""` | Key to populate with chunk keys (optional) |
| `batchMaxAttempts` | `2` | Retry attempts per batch job |
| `batchBackoff` | `60` | Seconds between retries |
| `batchTimeout` | `2400` | Job timeout in seconds |
| `batchAllowFailures` | `true` | Continue batch if some jobs fail |
| `batchFinally` | - | Job/chain to append after chained jobs complete |
| `batchCarryover` | `[]` | Props to pass to children; if empty, passes ALL props |

#### Output Props (added to child jobs)

| Prop | Value | Description |
| ---- | ----- | ----------- |
| `bBatchChild` | `true` | Flags this job as a batch child |
| `batchIndex` | `1-N` | 1-based index of this chunk |
| `batchTotal` | `N` | Total number of chunks |

### Adding a Finally Job

Use `batchFinally` in props to append a job after all chained jobs:

```cfml
// Single job object
props.batchFinally = cbq.job( "notification", { message : "All done!" } );

// Struct definition (converted to job)
props.batchFinally = {
    job : "reports.cleanup",
    properties : { bForce : true }
};

// Array of jobs
props.batchFinally = [
    cbq.job( "reports.summary", {} ),
    cbq.job( "notification", { message : "Reports complete" } )
];
```

### How It Works

1. **Threshold Check**: If `autoBatch` is enabled and items exceed `batchSize`, batching kicks in
2. **Chunking**: Items struct is split into chunks of `batchSize`
3. **Job Creation**: Each chunk becomes a new job with:
   - `bBatchChild = true` to flag as a batch child
   - `batchIndex` and `batchTotal` for progress tracking
   - `autoBatch = false` to prevent infinite recursion
4. **Chain Preservation**: Any chained jobs are moved to the batch's `finally()` callback
5. **Finally Append**: `batchFinally` is appended after existing chains
6. **Dispatch**: The batch is dispatched and the parent job exits early

### Module Settings

Configure defaults in your `config/ColdBox.cfc`:

```cfml
moduleSettings = {
    cbqAutoBatch : {
        defaultBatchSize : 10,
        defaultBatchQueue : "default",
        defaultMaxAttempts : 2,
        defaultBackoff : 60,
        defaultTimeout : 2400,
        defaultAllowFailures : true
    }
};
```

### Batch Progress Tracking

Batched jobs receive `batchIndex` and `batchTotal` in their props:

```cfml
function before() {
    var props = getProperties();
    if ( props.keyExists( "batchIndex" ) ) {
        notify( "Processing batch #props.batchIndex# of #props.batchTotal#" );
    }
}
```

### Controlling after() on Batch Children

Use `bBatchChild` to prevent `after()` from running on child jobs (run only on parent/finally):

```cfml
function after() {
    var props = getProperties();
    if ( !( props.bBatchChild ?: false ) ) {
        super.after(); // Only run on parent or finally job
    }
}
```

### Props Carryover Behavior

By default (empty `batchCarryover`), ALL props are passed to child jobs, substituting the chunked items. Use `batchCarryover` to explicitly limit which props are passed:

```cfml
// Default: all props carried over (recommended for most cases)
var result = autoBatch.evaluate( this, props );

// Explicit: only pass specific props to children
props.batchCarryover = [ "sessionGUID", "parentLogID", "bDebug" ];
var result = autoBatch.evaluate( this, props );
```

## License

MIT
