# gui/star_gate.rb — first-launch "star gate" for rpgm-decrypt-gui.
#
# Port of the RenpyEx GUI star gate (src/gui/star_gate.rs): the GUI asks the
# user to star the project on GitHub and verifies it before the main UI
# unlocks. Identity is proven with the GitHub OAuth **device flow**: the app
# requests a device code, the user approves it at github.com/login/device
# while signed in to *their own* account, and the app then checks
# GET /user/starred/{owner}/{repo} with the resulting token — 204 means the
# signed-in account stars the repository. No username is typed anywhere, so
# nobody can pass the gate with someone else's nickname.
#
# The result is persisted in config.json ("starred_by"), so already activated
# users never hit the network again and offline launches keep working. The
# token itself is only kept in memory and never written to disk.
# Best-effort only — it is a polite ask, not DRM.

require 'json'
require 'net/http'
require 'uri'

module RpgmStarGate
  # Repository whose star unlocks the GUI.
  REPO_URL = 'https://github.com/rolanfreeman6-png/rpgm-decrypt'
  # Where the user types the device code.
  DEVICE_VERIFICATION_URL = 'https://github.com/login/device'
  # Owner/repo pair (lowercase) checked for a star.
  OWNER_REPO = 'rolanfreeman6-png/rpgm-decrypt'
  # OAuth app client_id for the device flow. The device flow never uses the
  # client secret, so embedding the id in the bundle is safe. Requests an
  # empty scope — the token can only read public profile data.
  OAUTH_CLIENT_ID = 'Ov23liyHPi1XYLX3hrQB'
  UA = 'rpgm-decrypt-gui'

  module_function

  # POST a form body to a github.com endpoint; returns [http_status, body].
  def gh_post_form(url, body)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      req = Net::HTTP::Post.new(uri)
      req['User-Agent'] = UA
      req['Accept'] = 'application/json'
      req['Content-Type'] = 'application/x-www-form-urlencoded'
      req.body = body
      http.request(req)
    end
    [res.code.to_i, res.body.to_s]
  rescue StandardError => e
    [0, "network error: #{e.class}: #{e.message}"]
  end

  # GET with a bearer token; returns [http_status, body]. 4xx/5xx are surfaced
  # as status values — callers interpret per-endpoint meanings (404 on the
  # star check is "no star", not a transport failure).
  def gh_get(url, token)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      req = Net::HTTP::Get.new(uri)
      req['User-Agent'] = UA
      req['Accept'] = 'application/vnd.github+json'
      req['Authorization'] = "Bearer #{token}"
      http.request(req)
    end
    [res.code.to_i, res.body.to_s]
  rescue StandardError => e
    [0, "network error: #{e.class}: #{e.message}"]
  end

  # Request a device code. Returns
  # [[device_code, user_code, verification_uri, interval, expires_in], nil]
  # or [nil, error_message].
  def request_device_code
    code, body = gh_post_form('https://github.com/login/device/code',
                              "client_id=#{OAUTH_CLIENT_ID}&scope=")
    return [nil, code == 0 ? body : "GitHub error (HTTP #{code})"] if code != 200

    v = JSON.parse(body)
    dc = v['device_code'].to_s
    uc = v['user_code'].to_s
    return [nil, 'unexpected device-code response: missing fields'] if dc.empty? || uc.empty?

    [[dc, uc, v['verification_uri'] || DEVICE_VERIFICATION_URL,
      (v['interval'] || 5).to_i, (v['expires_in'] || 900).to_i], nil]
  rescue JSON::ParserError => e
    [nil, "unexpected device-code response: #{e.message}"]
  end

  # Poll the token endpoint once for the given device code. Returns
  # [:token, access_token], :pending, :slow_down, :expired, :denied or
  # [:failed, message].
  def poll_access_token(device_code)
    code, body = gh_post_form('https://github.com/login/oauth/access_token',
                              "client_id=#{OAUTH_CLIENT_ID}&device_code=#{device_code}" \
                              '&grant_type=urn:ietf:params:oauth:grant-type:device_code')
    return [:failed, code == 0 ? body : "GitHub error (HTTP #{code})"] if code != 200

    v = JSON.parse(body)
    return [:token, v['access_token']] if v['access_token']

    case v['error']
    when 'authorization_pending' then :pending
    when 'slow_down' then :slow_down
    when 'expired_token' then :expired
    when 'access_denied' then :denied
    else [:failed, "device flow error: #{v['error']}"]
    end
  rescue JSON::ParserError => e
    [:failed, "unexpected token response: #{e.message}"]
  end

  # With a user token: resolve the login and check the star. Returns
  # [:starred, login], [:not_starred, login] or [:failed, message].
  def verify_star(token)
    code, body = gh_get('https://api.github.com/user', token)
    return [:failed, code == 0 ? body : "GitHub API error (HTTP #{code})"] unless code == 200

    login = begin
      JSON.parse(body)['login'].to_s
    rescue JSON::ParserError
      ''
    end
    return [:failed, 'could not resolve GitHub login'] if login.empty?

    star_code, = gh_get("https://api.github.com/user/starred/#{OWNER_REPO}", token)
    case star_code
    when 204 then [:starred, login]
    # 404 from this endpoint means "signed in, but no star".
    when 404 then [:not_starred, login]
    else [:failed, "GitHub API error (HTTP #{star_code})"]
    end
  end

  # Blocking device flow for a background thread. Calls on_event.call(kind,
  # *args) with :device_code(user_code, verification_uri), :starred(login),
  # :not_starred(login, token), :denied(message) or :failed(message).
  # stop_check (optional) aborts the loop when it returns true.
  def run_device_flow(on_event, stop_check: nil)
    triple, err = request_device_code
    if err
      on_event.call(:failed, err)
      return
    end

    device_code, user_code, verification_uri, interval, expires_in = triple
    on_event.call(:device_code, user_code, verification_uri)
    deadline = Time.now + expires_in
    interval = 1 if interval < 1
    while Time.now < deadline
      return if stop_check&.call

      sleep interval
      st, payload = poll_access_token(device_code)
      case st
      when :token
        on_event.call(*verify_star_with_token(payload))
        return
      when :pending then nil
      when :slow_down then interval += 5
      when :expired
        on_event.call(:failed, 'device code expired — try again')
        return
      when :denied
        on_event.call(:denied, 'authorization was denied')
        return
      else
        on_event.call(:failed, payload.to_s)
        return
      end
    end
    on_event.call(:failed, 'device code expired — try again')
  end

  # Re-check the star with a token from a completed device flow (the user has
  # been asked to star the repo and pressed "check again").
  def recheck_star(token, on_event)
    on_event.call(*verify_star_with_token(token))
  end

  # verify_star plus the in-memory token for later re-checks.
  def verify_star_with_token(token)
    result = verify_star(token)
    result == [:not_starred, result[1]] ? [:not_starred, result[1], token] : result
  end

  # --- unlock persistence (config.json next to the exe) ---------------------
  def config_path(dir)
    File.join(dir, 'config.json')
  end

  # Returns the GitHub login that unlocked the GUI, or nil.
  def load_unlock(dir)
    path = config_path(dir)
    return nil unless File.exist?(path)

    login = JSON.parse(File.read(path))['starred_by'].to_s
    login.empty? ? nil : login
  rescue StandardError
    nil
  end

  def save_unlock(dir, login)
    File.write(config_path(dir), JSON.pretty_generate('starred_by' => login))
  rescue StandardError => e
    warn "[rpgm-gui] could not persist unlock: #{e.class}: #{e.message}"
  end
end
