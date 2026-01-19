component {

	this.name         = "cbq-autobatch";
	this.author       = "John Wilson";
	this.webUrl       = "https://github.com/Daemach/cbq-autobatch";
	this.cfmapping    = "cbq-autobatch";
	this.dependencies = [ "cbq" ];

	function configure() {
		settings = {
			// Default batch size if not specified in props
			"defaultBatchSize" : 10,
			// Default queue for batch jobs
			"defaultBatchQueue" : "default",
			// Default max attempts per batch job
			"defaultMaxAttempts" : 2,
			// Default backoff in seconds between retries
			"defaultBackoff" : 60,
			// Default individual job timeout in seconds (40 minutes)
			"defaultJobTimeout" : 2400,
			// Allow failures by default
			"defaultAllowFailures" : true
		};
	}

}
