component {

	this.name         = "cbqAutoBatch";
	this.author       = "John Wilson";
	this.webUrl       = "https://github.com/Daemach/cbq-autobatch";
	this.cfmapping    = "cbqAutoBatch";
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
			// Default timeout in seconds
			"defaultTimeout" : 2400,
			// Allow failures by default
			"defaultAllowFailures" : true
		};
	}

}
