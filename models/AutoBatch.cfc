/**
 * AutoBatch - Automatic job batching utility for cbq
 *
 * Evaluates whether a job should be split into smaller batches and dispatches them.
 * Jobs extending cbq's AbstractJob can use this to automatically chunk large workloads.
 *
 * Props contract (all in props, with defaults):
 * - autoBatch         : boolean (false)    - Enable auto-batching
 * - batchSize         : numeric (10)       - Items per batch
 * - batchQueue        : string ("default") - Queue/connection for batch jobs
 * - batchItemsKey     : string ("items")   - Key in props containing struct to chunk
 * - batchMaxAttempts  : numeric (2)        - Max attempts per child job
 * - batchBackoff      : numeric (60)       - Seconds between retries per child job
 * - batchJobTimeout   : numeric (2400)     - Timeout per child job in seconds
 * - batchAllowFailures: boolean (true)     - Continue batch if some jobs fail
 * - batchThen         : any                - Job/chain to run immediately after batch, before chained jobs
 * - batchFinally      : any                - Job/chain to run after all chained jobs complete
 * - batchCarryover    : array              - Props keys to pass to child jobs; if empty, passes ALL props
 *
 * Output props added to child jobs:
 * - bBatchChild       : boolean (true)     - Flags job as a batch child
 * - batchIndex        : numeric            - 1-based index of this chunk
 * - batchTotal        : numeric            - Total number of chunks
 *
 * @singleton
 */
component singleton threadsafe accessors="true" {

	property name="cbq"      inject="cbq@cbq";
	property name="settings" inject="coldbox:moduleSettings:cbq-autobatch";

	/**
	 * Evaluates whether a job should auto-batch and dispatches if threshold exceeded.
	 * All configuration is derived from props - no additional arguments needed.
	 *
	 * @job   The job instance (must extend cbq AbstractJob with whoami(), getChained())
	 * @props Job properties struct containing items to batch and batch configuration
	 *
	 * @return { batched: boolean, result: any } - if batched=true, caller should return early
	 */
	struct function evaluate( required any job, required struct props ) {
		// Apply defaults from settings
		param props.autoBatch = false;
		param props.batchSize = settings.defaultBatchSize;
		param props.batchQueue = settings.defaultBatchQueue;
		param props.batchItemsKey = "items";
		param props.batchCarryover = [];

		// Guard: autoBatch disabled
		if ( !props.autoBatch ) {
			return { batched : false };
		}

		var itemsKey = props.batchItemsKey;

		// Guard: items key missing or not a struct
		if ( !props.keyExists( itemsKey ) || !isStruct( props[ itemsKey ] ) ) {
			notifyJob( job, "AutoBatch => Skipping: '#itemsKey#' is missing or not a struct" );
			return { batched : false };
		}

		var items = props[ itemsKey ];

		// Guard: below threshold
		if ( items.len() <= props.batchSize ) {
			return { batched : false };
		}

		return {
			batched : true,
			result : dispatch( job, props )
		};
	}

	/**
	 * Dispatches a batch job, splitting items into chunks.
	 * Transfers any chained jobs to the batch's finally() callback.
	 *
	 * @job   The job instance
	 * @props Job properties (contains all batch config)
	 *
	 * @return Result from batch.dispatch()
	 */
	private any function dispatch( required any job, required struct props ) {
		var jobName = listLast( job.whoami(), "." );
		var jobMapping = job.whoami().replace( "models.", "" );
		var itemsKey = props.batchItemsKey;
		var items = props[ itemsKey ];
		var chunks = structChunk( items, props.batchSize );
		var batchItems = [];

		// Notify batch creation
		notifyJob( job, "#jobName##chr( 9 )#=> Auto-batching (#props.batchQueue#) items:[#items.len()#] batches:[#chunks.len()#] per:[#props.batchSize#]" );

		// Build batch job items
		var excludeKeys = [ "logID", itemsKey, "batchCarryover" ];
		var carryover = isArray( props.batchCarryover ) ? props.batchCarryover : [];

		chunks.each( ( chunk, idx ) => {
			var jobProps = {};

			// Carry over props: if batchCarryover defined, use only those; otherwise carry all (minus excluded)
			if ( carryover.len() ) {
				carryover.each( ( key ) => {
					if ( isSimpleValue( key ) && len( key ) && props.keyExists( key ) ) {
						jobProps[ key ] = props[ key ];
					}
				} );
			} else {
				props.each( ( key, value ) => {
					if ( !excludeKeys.find( key ) ) {
						jobProps[ key ] = value;
					}
				} );
			}

			// Standard batch props (override any carried over)
			jobProps[ itemsKey ] = chunk;
			jobProps.bBatchChild = true; // Flag as batch child
			jobProps.batchIndex = idx;
			jobProps.batchTotal = chunks.len();
			jobProps.autoBatch = false; // Prevent infinite re-batching

			var jobTimeout = props.batchJobTimeout ?: settings.defaultJobTimeout;
			var jobMaxAttempts = props.batchMaxAttempts ?: settings.defaultMaxAttempts;
			var jobBackoff = props.batchBackoff ?: settings.defaultBackoff;
			batchItems.append(
				cbq.job( jobMapping, jobProps, [], "low", props.batchQueue )
					.setTimeout( jobTimeout )
					.setMaxAttempts( jobMaxAttempts )
					.setBackoff( jobBackoff )
			);
		}, true );

		// Configure batch
		var batch = cbq
			.batch( batchItems )
			.onQueue( "low" )
			.onConnection( props.batchQueue )
			.allowFailures( props.batchAllowFailures ?: settings.defaultAllowFailures );

		// Transfer chained jobs to batch finally()
		var batchThen = props.batchThen ?: "";
		var batchFinally = props.batchFinally ?: "";
		attachChainedJobs( batch, job, jobMapping, batchThen, batchFinally );

		notifyJob( job, "#jobName##chr( 9 )#=> Dispatching batch" );

		return batch.dispatch();
	}

	/**
	 * Translates and attaches chained jobs to batch.finally()
	 * Execution order: batchThen → chained jobs → batchFinally
	 * If no jobs provided, adds a default completion message.
	 *
	 * @batch      The cbq batch instance
	 * @job        The originating job instance
	 * @jobMapping The job mapping name for message
	 * @then       Job/chain to run immediately after batch completes
	 * @finally    Job/chain to run after all chained jobs complete
	 */
	private void function attachChainedJobs(
		required any batch,
		required any job,
		required string jobMapping,
		any then = "",
		any finally = ""
	) {
		var chainedJobs = job.getChained();
		var translatedJobs = [];

		// Guard: ensure chainedJobs is an array
		if ( !isArray( chainedJobs ) ) {
			chainedJobs = [];
		}

		// 1. Add batchThen first (runs immediately after batch)
		appendJobsToArray( translatedJobs, then );

		// 2. Translate and add existing chained jobs
		if ( chainedJobs.len() > 0 ) {
			chainedJobs.each( ( chain ) => {
				if ( !isStruct( chain ) ) {
					return;
				}
				var translated = cbq.job(
					job : safeGet( chain, "mapping", "", "string" ),
					properties : safeGet( chain, "properties", {}, "struct" ),
					chain : safeGet( chain, "chained", [], "array" ),
					queue : safeGet( chain, "queue", "default", "string" ),
					connection : safeGet( chain, "connection", "default", "string" ),
					backoff : safeGet( chain, "backoff", 0, "numeric" ),
					timeout : safeGet( chain, "timeout", 60, "numeric" ),
					maxAttempts : safeGet( chain, "maxAttempts", 1, "numeric" )
				);
				if ( isObject( translated ) ) {
					translatedJobs.append( translated );
				}
			} );
		}

		// 3. Add batchFinally last (runs after all chained jobs)
		appendJobsToArray( translatedJobs, finally );

		// Attach to batch
		if ( translatedJobs.len() > 0 ) {
			batch.finally( cbq.chain( translatedJobs ) );
		} else {
			batch.finally( cbq.job( "message", {
				message : "Batch job for #jobMapping# complete!",
				bSeparator : 1,
				bSeparatorBefore : 1
			} ) );
		}
	}

	/**
	 * Appends job(s) to an array from various input formats.
	 * Handles: job objects, arrays of jobs, struct definitions, or empty values.
	 *
	 * @target The array to append to
	 * @source The job source (object, array, struct, or empty string)
	 */
	private void function appendJobsToArray( required array target, any source = "" ) {
		if ( isSimpleValue( source ) && len( source ) == 0 ) {
			return;
		}

		if ( isArray( source ) && source.len() > 0 ) {
			target.append( source.filter( ( j ) => isObject( j ) ), true );
		} else if ( isObject( source ) ) {
			target.append( source );
		} else if ( isStruct( source ) && source.count() > 0 ) {
			var jobMapping = safeGet( source, "job", safeGet( source, "mapping", "", "string" ), "string" );
			if ( len( jobMapping ) ) {
				var jobChain = safeGet( source, "chain", safeGet( source, "chained", [], "array" ), "array" );
				target.append( cbq.job(
					job : jobMapping,
					properties : safeGet( source, "properties", {}, "struct" ),
					chain : jobChain,
					queue : safeGet( source, "queue", "default", "string" ),
					connection : safeGet( source, "connection", "default", "string" ),
					backoff : safeGet( source, "backoff", 0, "numeric" ),
					timeout : safeGet( source, "timeout", 60, "numeric" ),
					maxAttempts : safeGet( source, "maxAttempts", 1, "numeric" )
				) );
			}
		}
	}

	/**
	 * Chunks a struct into an array of smaller structs.
	 *
	 * @source    The source struct to chunk
	 * @chunkSize Maximum items per chunk
	 *
	 * @return    Array of structs
	 */
	private array function structChunk( required struct source, required numeric chunkSize ) {
		var keys = source.keyArray();
		var chunks = [];
		var currentChunk = {};
		var count = 0;

		for ( var key in keys ) {
			currentChunk[ key ] = source[ key ];
			count++;

			if ( count >= chunkSize ) {
				chunks.append( currentChunk );
				currentChunk = {};
				count = 0;
			}
		}

		// Append remaining items
		if ( currentChunk.count() > 0 ) {
			chunks.append( currentChunk );
		}

		return chunks;
	}

	/**
	 * Sends notification via job's pusherWrapper if available.
	 *
	 * @job     The job instance
	 * @message Message to send
	 */
	private void function notifyJob( required any job, required string message ) {
		if ( structKeyExists( job, "pusherWrapper" ) ) {
			job.pusherWrapper( message );
		}
	}

	/**
	 * Null-safe struct value accessor with type validation.
	 *
	 * @source   The struct to read from
	 * @key      The key to access
	 * @default  Default value if key missing or wrong type
	 * @type     Expected type: "string", "numeric", "array", "struct", "any"
	 *
	 * @return   The value or default
	 */
	private any function safeGet( required struct source, required string key, required any default, string type = "any" ) {
		if ( !source.keyExists( key ) ) {
			return default;
		}

		var value = source[ key ];

		switch ( type ) {
			case "string":
				return ( isSimpleValue( value ) && len( value ) ) ? value : default;
			case "numeric":
				return isNumeric( value ) ? value : default;
			case "array":
				return isArray( value ) ? value : default;
			case "struct":
				return isStruct( value ) ? value : default;
			default:
				return value;
		}
	}
	// "I am the way, and the truth, and the life; no one comes to the Father, but by me (JESUS)" Jn 14:1-12

}
