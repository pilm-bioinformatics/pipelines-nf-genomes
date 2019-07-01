#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/genomes
========================================================================================
 nf-core/genomes Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/genomes
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/genomes --fasta genome.fa --gtf transcript.gtf --genome GRCh38 --release 96 -profile docker

    Mandatory arguments:
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference
      --gtf                         GTF file
      --genome
      --release
      --organism

    Tools
      --star
      --hisat2
      --rnaseq

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// TODO nf-core: Add any reference files that are needed
if( !params.release ) exit 1, "--release need to be set up"
if( !params.genome ) exit 1, "--genome need to be set up"
if( !params.organism ) exit 1, "--organism need to be set up"

outdir = "${params.outdir}/${params.organism}/${params.genome}.${params.release}"

// Configurable reference genomes
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the above in a process, define the following:
//   input:
//   file fasta from fasta
//
Channel.fromPath(params.fasta)
       .ifEmpty { exit 1, "Fasta file not found: ${params.fasta}" }
       .set { ch_fasta_for_cp }

Channel.fromPath(params.gtf)
       .ifEmpty { exit 1, "gtf file not found: ${params.gtf}" }
       .set { ch_gtf_for_cp }


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Fasta Ref']        = params.fasta
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-genomes-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/genomes Workflow Summary'
    section_href: 'https://github.com/nf-core/genomes'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${outdir}/pipeline_info", mode: 'copy',
    saveAs: {filename ->
        if (filename.indexOf(".csv") > 0) filename
        else null
    }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

process copy_fasta {
  publishDir path: { "${outdir}/seq"},
  mode: 'copy'

  input:
  file fasta from ch_fasta_for_cp

  output:
  file "${params.genome}.${params.release}.fa" into ch_fasta_for_star_index, ch_fasta_for_hisat_index, ch_fasta_for_txome, ch_fasta_for_gentrome, ch_fasta_for_config
  file "${params.genome}.${params.release}.fa.fai"
  
  script:
  """
  cp ${fasta} ${params.genome}.${params.release}.fa
  samtools faidx ${params.genome}.${params.release}.fa
"""
}

process copy_gtf {
  publishDir path: { "${outdir}/rnaseq"},
  mode: 'copy'

  input:
  file gtf from ch_gtf_for_cp

  output:
  file "${params.genome}.${params.release}.gtf" into gtf_makeHisatSplicesites, gtf_makeHISATindex, gtf_makeSTARindex, ch_gtf_for_txome, ch_gtf_for_gentrome, ch_gtf_for_config
  file "${params.genome}.${params.release}_pre.gtf" into ch_pre_gtf
  
  script:
  """
  cp ${gtf} ${params.genome}.${params.release}.gtf
  awk '\$3=="transcript"' ${gtf}  | sed 's/\ttranscript\t/\texon\t/' > ${params.genome}.${params.release}_pre.gtf
  """
}

/*
 * GENOME INDEX - Build STAR index
 */
if(params.star &&  params.fasta){
    process makeSTARindex {
        label 'high_memory'
        tag "$fasta"
        publishDir path: { "${outdir}" },
                   mode: 'copy'

        input:
        file fasta from ch_fasta_for_star_index
        file gtf from gtf_makeSTARindex

        output:
        file "star" into star_index

        script:
        def avail_mem = task.memory ? "--limitGenomeGenerateRAM ${task.memory.toBytes() - 100000000}" : ''
        """
        mkdir star
        STAR \\
            --runMode genomeGenerate \\
            --runThreadN ${task.cpus} \\
            --sjdbGTFfile $gtf \\
            --genomeDir star/ \\
            --genomeFastaFiles $fasta \\
            $avail_mem
        """
    }
}

/*
 * PREPROCESSING - Build HISAT2 splice sites file
 */
if(params.hisat2 && params.gtf){
    process makeHisatSplicesites {
        tag "$gtf"
        publishDir path: { "${outdir}/hisat2" },
                   mode: 'copy'

        input:
        file gtf from gtf_makeHisatSplicesites

        output:
        file "${gtf.baseName}.hisat2_splice_sites.txt" into indexing_splicesites, alignment_splicesites

        script:
        """
        hisat2_extract_splice_sites.py $gtf > ${gtf.baseName}.hisat2_splice_sites.txt
        """
    }
}

/*
 * GENOME INDEX - Build HISAT2 index
 */
if(params.hisat2 && params.fasta){
    process makeHISATindex {
        tag "$fasta"
        publishDir path: { "${outdir}/hisat2" },
                   mode: 'copy'

        input:
        file fasta from ch_fasta_for_hisat_index
        file indexing_splicesites from indexing_splicesites
        file gtf from gtf_makeHISATindex

        output:
        file "${fasta.baseName}.*.ht2*" into hs2_indices

        script:
        if( !task.memory ){
            log.info "[HISAT2 index build] Available memory not known - defaulting to 0. Specify process memory requirements to change this."
            avail_mem = 0
        } else {
            log.info "[HISAT2 index build] Available memory: ${task.memory}"
            avail_mem = task.memory.toGiga()
        }
        if( avail_mem > params.hisatBuildMemory ){
            log.info "[HISAT2 index build] Over ${params.hisatBuildMemory} GB available, so using splice sites and exons in HISAT2 index"
            extract_exons = "hisat2_extract_exons.py $gtf > ${gtf.baseName}.hisat2_exons.txt"
            ss = "--ss $indexing_splicesites"
            exon = "--exon ${gtf.baseName}.hisat2_exons.txt"
        } else {
            log.info "[HISAT2 index build] Less than ${params.hisatBuildMemory} GB available, so NOT using splice sites and exons in HISAT2 index."
            log.info "[HISAT2 index build] Use --hisatBuildMemory [small number] to skip this check."
            extract_exons = ''
            ss = ''
            exon = ''
        }
        """
        $extract_exons
        hisat2-build -p ${task.cpus} $ss $exon $fasta ${fasta.baseName}.hisat2_index
        """
    }
}


/*
 * gtf to txome 
 */
if(params.rnaseq){
  process makeTxome {
  publishDir path: { "${outdir}/rnaseq"},
  mode: 'copy'
  
  input:
  file fasta from ch_fasta_for_txome
  file gtf from ch_gtf_for_txome
  file pre_gtf from ch_pre_gtf

  output:
  file "tx_${gtf.baseName}.fa" into ch_txfasta_for_gentrome, ch_txfasta_for_config
  file "tx_${pre_gtf.baseName}.fa" into ch_pre_txfasta_for_config

  script:
  """
  gffread -w tx_${gtf.baseName}.fa -g $fasta $gtf
  gffread -w tx_${pre_gtf.baseName}.fa -g $fasta $gtf
  """
}
}

/*
 * gentrome 
 */
if(params.rnaseq){
  process makeGentrome {
  publishDir path: { "${outdir}/rnaseq"},
  mode: 'copy'
  
  input:
  file fasta from ch_fasta_for_gentrome
  file gtf from ch_gtf_for_gentrome
  file txome from ch_txfasta_for_gentrome
  
  output:
  file 'gentrome.fa' into ch_gentrome_for_config
  file 'decoys.txt' into ch_decoys_for_config
  
  script:
  """
  wget https://github.com/COMBINE-lab/SalmonTools/raw/master/scripts/generateDecoyTranscriptome.sh
  chmod +x generateDecoyTranscriptome.sh
  ./generateDecoyTranscriptome.sh -j ${task.cpus} -a $gtf -g $fasta -t $txome -o .
  """
}
}


process config_file {
  publishDir "${outdir}", mode: 'copy'
  
  input:
  file fasta from ch_fasta_for_config
  file gtf from ch_gtf_for_config
  file txfasta from ch_txfasta_for_config
  file pre_txfasta from ch_pre_txfasta_for_config
  file gentrome from ch_gentrome_for_config
  file decoys from ch_decoys_for_config
  
  output:
  file "${params.genome}.${params.release}.config"
  
  
  script:
  hisat2_index = ""
  star_index = ""
  base_genome = "${params.organism}/${params.genome}.${params.release}"
  if (params.hisat2) {hisat2_index = "hisat2_index = \\\"\\\${params.genome_path}/${base_genome}/hisat2/${params.genome}.${params.release}.hisat2_index\\\""}
  if (params.star) {star_index = "star_index = \\\"\\\${params.genome_path}/${base_genome}/star\\\""}
  config = "${params.genome}.${params.release}.config"
  """
  echo "// params.genome_path = ${params.outdir}" >> $config
  echo "params {" >> $config
  echo "  fasta = \\\"\\\${params.genome_path}/${base_genome}/seq/$fasta\\\"" >>$config
  echo "  transcriptome = \\\"\\\${params.genome_path}/${base_genome}/rnaseq/$txfasta\\\"" >>$config
  echo "  pre_transcriptome = \\\"\\\${params.genome_path}/${base_genome}/rnaseq/$pre_txfasta\\\"" >>$config
  echo "  gtf = \\\"\\\${params.genome_path}/${base_genome}/rnaseq/$gtf\\\"" >>$config
  echo "  gentrome = \\\"\\\${params.genome_path}/${base_genome}/rnaseq/$gentrome\\\"" >>$config
  echo "  decoys = \\\"\\\${params.genome_path}/${base_genome}/rnaseq/$decoys\\\"" >>$config
  echo "  $hisat2_index" >>$config
  echo "  $star_index" >>$config
  echo "}" >>$config
  """
  
}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    # markdown_to_html.r $output_docs results_description.html
    touch results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/genomes] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/genomes] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/genomes] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/genomes] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCountFmt > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/genomes]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/genomes]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/genomes v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
