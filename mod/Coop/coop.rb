#==============================================================================
# Changed Co-op — online co-op for 2+ players (host-authoritative)
#------------------------------------------------------------------------------
# Loaded by Coop/Boot.rvdata right before the game's Main script.
# RGSS2 / Ruby 1.8.1: no Symbol#to_proc, no ->, no String#bytesize, etc.
#
# The host plays the real game. Clients mirror the host's world (events, screen,
# pictures, messages, audio, switches) and walk around with their own character.
# Enemies chase the nearest living player. A caught player becomes a latex
# ghost until a teammate revives them (action key next to them) or the group
# changes map. Game over happens only when every player has been caught.
#==============================================================================

module Coop
  VERSION = "0.1.0"
  DIR = "Coop"
  INI = "./Coop/coop.ini"

  #--------------------------------------------------------------------------
  # helpers
  #--------------------------------------------------------------------------
  def self.hooked?(klass, name)
    klass.method_defined?(name) || klass.private_method_defined?(name)
  end

  def self.gv(o, name)
    o.instance_variable_get(name)
  end

  def self.sv(o, name, v)
    o.instance_variable_set(name, v)
  end

  def self.log(msg)
    File.open(DIR + "/coop.log", "a") do |f|
      f.write(sprintf("[%07d] %s\n", Graphics.frame_count, msg.to_s))
    end
  rescue Exception
  end

  def self.log_error(where, e)
    log("#{where}: #{e.class}: #{e.message}\n  " + (e.backtrace || [])[0, 8].join("\n  "))
  end

  GetIni = Win32API.new("kernel32", "GetPrivateProfileString", "ppppip", "i")
  SetIni = Win32API.new("kernel32", "WritePrivateProfileString", "pppp", "i")

  def self.ini(key, default)
    buf = "\0" * 256
    n = GetIni.call("Coop", key, default.to_s, buf, 256, INI)
    buf[0, n]
  end

  def self.set_ini(key, value)
    SetIni.call("Coop", key, value.to_s, INI)
  end

  #--------------------------------------------------------------------------
  # Safe serializer (never Marshal.load data from the network)
  #--------------------------------------------------------------------------
  module Pack
    def self.dump(o)
      s = ""
      w(o, s)
      s
    end

    def self.w(o, s)
      if o.nil? then s << "n"
      elsif o == true then s << "t"
      elsif o == false then s << "f"
      elsif o.is_a?(Integer)
        if o >= -2147483648 && o <= 2147483647
          s << "i" << [o].pack("l")
        else
          x = o.to_s
          s << "I" << [x.size].pack("L") << x
        end
      elsif o.is_a?(Float) then s << "d" << [o].pack("E")
      elsif o.is_a?(String) then s << "s" << [o.size].pack("L") << o
      elsif o.is_a?(Symbol)
        x = o.to_s
        s << "y" << [x.size].pack("L") << x
      elsif o.is_a?(Array)
        s << "a" << [o.size].pack("L")
        o.each { |e| w(e, s) }
      elsif o.is_a?(Hash)
        s << "h" << [o.size].pack("L")
        o.each { |k, v| w(k, s); w(v, s) }
      else
        s << "n"
      end
    end

    def self.load(s)
      r = [s, 0]
      rd(r)
    end

    def self.rd(r)
      s = r[0]
      t = s[r[1], 1]
      r[1] += 1
      case t
      when "n" then return nil
      when "t" then return true
      when "f" then return false
      when "i"
        v = s[r[1], 4].unpack("l")[0]
        r[1] += 4
        return v
      when "d"
        v = s[r[1], 8].unpack("E")[0]
        r[1] += 8
        return v
      when "s", "y", "I"
        n = s[r[1], 4].unpack("L")[0]
        r[1] += 4
        v = s[r[1], n]
        r[1] += n
        return v.intern if t == "y"
        return v.to_i if t == "I"
        return v
      when "a"
        n = s[r[1], 4].unpack("L")[0]
        r[1] += 4
        a = []
        n.times { a << rd(r) }
        return a
      when "h"
        n = s[r[1], 4].unpack("L")[0]
        r[1] += 4
        h = {}
        n.times do
          k = rd(r)
          h[k] = rd(r)
        end
        return h
      end
      raise "bad pack tag #{t.inspect}"
    end
  end

  #--------------------------------------------------------------------------
  # Winsock (ws2_32) through Win32API
  #--------------------------------------------------------------------------
  module WS
    def self.api(name, args, ret)
      Win32API.new("ws2_32", name, args, ret)
    end
    Startup   = api("WSAStartup", "ip", "i")
    Sock      = api("socket", "iii", "i")
    Bind      = api("bind", "ipi", "i")
    Listen    = api("listen", "ii", "i")
    Accept    = api("accept", "ipp", "i")
    Connect   = api("connect", "ipi", "i")
    Send      = api("send", "ipii", "i")
    Recv      = api("recv", "ipii", "i")
    Close     = api("closesocket", "i", "i")
    Ioctl     = api("ioctlsocket", "iip", "i")
    SetOpt    = api("setsockopt", "iiipi", "i")
    Select    = api("select", "ipppp", "i")
    LastError = api("WSAGetLastError", "v", "i")
    HostByName = api("gethostbyname", "p", "i")
    Mem = Win32API.new("kernel32", "RtlMoveMemory", "pii", "v")
    WOULDBLOCK = 10035
    FIONBIO = -2147195266   # 0x8004667E

    def self.init
      return if @inited
      Startup.call(0x0202, "\0" * 512)
      @inited = true
    end

    def self.err
      LastError.call
    end

    def self.sockaddr(ip4, port)
      [2, port].pack("vn") + ip4 + "\0" * 8
    end

    def self.resolve(host)
      host = host.strip
      if host =~ /\A(\d+)\.(\d+)\.(\d+)\.(\d+)\z/
        return [$1.to_i, $2.to_i, $3.to_i, $4.to_i].pack("C4")
      end
      ptr = HostByName.call(host)
      return nil if ptr == 0
      he = "\0" * 16
      Mem.call(he, ptr, 16)
      list = he.unpack("LLssL")[4]
      return nil if list == 0
      p0 = "\0" * 4
      Mem.call(p0, list, 4)
      a = p0.unpack("L")[0]
      return nil if a == 0
      ip = "\0" * 4
      Mem.call(ip, a, 4)
      ip
    end

    def self.nonblock(s)
      Ioctl.call(s, FIONBIO, [1].pack("L"))
    end

    def self.nodelay(s)
      SetOpt.call(s, 6, 1, [1].pack("l"), 4)
    end
  end

  # One framed TCP connection.
  class Conn
    attr_reader :sock, :alive
    attr_accessor :pid, :name, :ready

    def initialize(sock)
      @sock = sock
      @in = ""
      @out = ""
      @alive = true
      @buf = "\0" * 65536
      @pid = -1
      @ready = false
    end

    def self.frame(msg)
      data = Pack.dump(msg)
      flag = 0
      if data.size > 512
        z = Zlib::Deflate.deflate(data)
        if z.size < data.size
          data = z
          flag = 1
        end
      end
      [data.size + 1].pack("N") + flag.chr + data
    end

    def send_msg(msg)
      send_frame(Conn.frame(msg))
    end

    def send_frame(f)
      return unless @alive
      @out << f
      close if @out.size > 16 * 1024 * 1024
    end

    def flush
      while @alive && @out.size > 0
        len = @out.size
        len = 65536 if len > 65536
        n = WS::Send.call(@sock, @out, len, 0)
        if n > 0
          @out[0, n] = ""
        elsif n < 0 && WS.err == WS::WOULDBLOCK
          break
        else
          close
        end
      end
    end

    def poll
      msgs = []
      return msgs unless @alive
      16.times do
        n = WS::Recv.call(@sock, @buf, @buf.size, 0)
        if n > 0
          @in << @buf[0, n]
        elsif n == 0
          close
          break
        else
          close unless WS.err == WS::WOULDBLOCK
          break
        end
      end
      loop do
        break if @in.size < 4
        len = @in[0, 4].unpack("N")[0]
        break if @in.size < 4 + len
        flag = @in[4, 1]
        data = @in[5, len - 1]
        @in[0, 4 + len] = ""
        data = Zlib::Inflate.inflate(data) if flag == "\001"
        msgs << Pack.load(data)
      end
      msgs
    rescue Exception => e
      Coop.log_error("poll", e)
      close
      msgs
    end

    def close
      return unless @alive
      @alive = false
      WS::Close.call(@sock)
    end
  end

  #--------------------------------------------------------------------------
  # State
  #--------------------------------------------------------------------------
  TINTS = [nil, [-50, -10, 80, 0], [-40, 60, -40, 0], [80, -10, -60, 0],
           [60, -50, 80, 0], [70, 60, -60, 0], [-60, 50, 80, 0], [40, 40, 40, 60]]
  NAME_COLORS = [[255, 255, 255], [120, 170, 255], [120, 255, 140], [255, 170, 90],
                 [230, 130, 255], [255, 240, 110], [110, 240, 240], [200, 200, 200]]
  LOC_CHARS = ["$!03", "$!07", "$!13", "$!14", "$!15", "$!16", "$!19"]
  ENEMY_CODES = [0, 108, 408, 121, 122, 123, 230, 250]

  @mode = :off
  @me = 0
  @names = {}
  @pstates = {}
  @downed = {}
  @chars = {}
  @conns = []
  @toasts = []
  @tick = 0

  class << self
    attr_reader :mode, :me, :names, :pstates, :downed, :chars, :status
    attr_accessor :fwd_kind
  end

  def self.host?;   @mode == :host;   end
  def self.client?; @mode == :client; end
  def self.active?; @mode != :off;    end

  def self.local_downed?
    active? && @downed[@me] ? true : false
  end

  def self.my_name
    n = ini("Name", "Player").strip
    n.empty? ? "Player" : n[0, 16]
  end

  def self.reset_session
    @names = {}
    @pstates = {}
    @downed = {}
    @chars = {}
    @conns = []
    @ev_last = {}
    @ev_map = nil
    @ev_cache = {}
    @ev_dirty = {}
    @host_map = nil
    @applied_map = nil
    @scr_last = nil
    @pic_last = {}
    @vars_last = nil
    @ps_dirty = true
    @msg_seq = 0
    @cur_seq = 0
    @msg_queue = []
    @msg_keys = []
    @pending_world = nil
    @pending_map = nil
    @goto_scene = nil
    @in_world = false
    @gameover = false
    @chaser_pages = {}
    @chaser_list = []
    @fwd_cool = {}
    @last_me = nil
    @host_bgm = nil
    @host_bgs = nil
    @ghost = false
    @connecting = nil
    @server = nil
    @listen = nil
    @sys_se = 0
    @audio_mute = false
  end
  reset_session

  #--------------------------------------------------------------------------
  # Session control
  #--------------------------------------------------------------------------
  def self.host_start(port)
    stop if active?
    WS.init
    s = WS::Sock.call(2, 1, 6)
    return "socket() failed (#{WS.err})" if s == -1
    if WS::Bind.call(s, WS.sockaddr("\0\0\0\0", port), 16) != 0
      e = WS.err
      WS::Close.call(s)
      return "Port #{port} is busy (error #{e})"
    end
    WS::Listen.call(s, 8)
    WS.nonblock(s)
    reset_session
    @listen = s
    @mode = :host
    @me = 0
    @next_pid = 1
    @names = { 0 => my_name }
    @status = "Hosting on port #{port}"
    log("host started on #{port} as #{my_name}")
    toast("Hosting co-op on port #{port}")
    nil
  end

  def self.join(host, port)
    stop if active?
    WS.init
    ip = WS.resolve(host)
    return "Can't resolve \"#{host}\"" unless ip
    s = WS::Sock.call(2, 1, 6)
    return "socket() failed (#{WS.err})" if s == -1
    WS.nonblock(s)
    WS.nodelay(s)
    WS::Connect.call(s, WS.sockaddr(ip, port), 16)
    reset_session
    @mode = :client
    @me = -1
    @connecting = [s, Graphics.frame_count, "#{host}:#{port}"]
    @status = "Connecting to #{host}:#{port}..."
    log("connecting to #{host}:#{port}")
    nil
  end

  def self.stop(reason = nil)
    if client? && @server
      @server.send_msg([:bye])
      @server.flush
      @server.close
    end
    WS::Close.call(@connecting[0]) if @connecting
    if host?
      @conns.each { |c| c.send_msg([:bye]); c.flush; c.close }
      WS::Close.call(@listen) if @listen
    end
    was = @mode
    @mode = :off
    reset_session
    @status = reason || "Offline"
    toast(reason) if reason
    log("stopped (#{was}): #{reason}")
    refresh_local_look
  end

  #--------------------------------------------------------------------------
  # Network pump — runs every Graphics.update in every scene
  #--------------------------------------------------------------------------
  def self.pump
    overlay_update
    return unless active?
    if host?
      host_accept
      @conns.each do |c|
        next unless c.alive
        c.poll.each { |m| host_recv(c, m) }
      end
      dead = @conns.select { |c| !c.alive }
      dead.each { |c| host_drop(c) }
      @conns.each { |c| c.flush }
    else
      client_check_connecting if @connecting
      if @server
        @server.poll.each { |m| client_recv(m) }
        @server.flush
        client_lost unless @server.alive
      end
      if client? && @pending_world && !@in_world
        client_enter_world
      end
    end
  rescue Exception => e
    log_error("pump", e)
  end

  def self.broadcast(msg)
    f = nil
    @conns.each do |c|
      next unless c.ready && c.alive
      f ||= Conn.frame(msg)
      c.send_frame(f)
    end
  end

  def self.toast(s)
    @toasts << [s.to_s, 300]
    @overlay_dirty = true
    log("toast: #{s}")
  end

  #--------------------------------------------------------------------------
  # HOST side
  #--------------------------------------------------------------------------
  def self.host_accept
    4.times do
      c = WS::Accept.call(@listen, nil, nil)
      break if c == -1 || c == 0
      WS.nonblock(c)
      WS.nodelay(c)
      @conns << Conn.new(c)
      log("accepted socket #{c}")
    end
  end

  def self.host_recv(c, m)
    case m[0]
    when :hello
      if m[2] != VERSION
        c.send_msg([:reject, "Version mismatch: host has co-op #{VERSION}, you have #{m[2]}"])
        c.flush
        c.close
        return
      end
      c.pid = @next_pid
      @next_pid += 1
      c.name = m[1].to_s[0, 16]
      @names[c.pid] = c.name
      c.send_msg([:welcome, c.pid, @names])
      toast("#{c.name} joined (P#{c.pid + 1})")
      c.ready = true
      broadcast([:names, @names])
      broadcast([:toast, "#{c.name} joined (P#{c.pid + 1})"])
      send_world(c) if in_map_scene?
    when :me
      return if c.pid < 0
      @pstates[c.pid] = m[1]
      @ps_dirty = true
    when :start
      host_net_start(c.pid, m[1], m[2])
    when :revive
      host_revive(m[1], c.pid)
    when :bye
      c.close
    end
  end

  def self.host_drop(c)
    @conns.delete(c)
    return if c.pid < 0
    name = @names[c.pid]
    @names.delete(c.pid)
    @pstates.delete(c.pid)
    @downed.delete(c.pid)
    @chars.delete(c.pid)
    toast("#{name} left")
    broadcast([:leave, c.pid])
    broadcast([:toast, "#{name} left"])
    # nobody alive anymore (the survivor left)? bring the host back
    if @names.keys.all? { |p| @downed[p] }
      @downed = {}
      broadcast([:down, @downed])
      refresh_local_look
    end
  end

  def self.in_map_scene?
    $scene.is_a?(Scene_Map) && $game_map && $game_map.map_id > 0
  end

  def self.world_msg
    [:world, {
      "map" => $game_map.map_id, "x" => $game_player.x, "y" => $game_player.y,
      "dir" => $game_player.direction, "vars" => vars_snapshot,
      "names" => @names, "ps" => @pstates, "down" => @downed,
      "screen" => screen_full, "bgm" => @host_bgm, "bgs" => @host_bgs
    }]
  end

  def self.send_world(c)
    @pstates[0] = local_state
    c.send_msg(world_msg)
    c.send_msg([:ev, $game_map.map_id, all_event_states])
    c.ready = true
  end

  def self.on_map_scene_start
    if host?
      @pstates[0] = local_state
      w = nil
      @conns.each do |c|
        next unless c.alive && c.pid >= 0
        w ||= Conn.frame(world_msg)
        c.send_frame(w)
        c.send_msg([:ev, $game_map.map_id, all_event_states])
        c.ready = true
      end
    elsif client?
      @applied_map = nil
    end
  end

  def self.local_state
    p = $game_player
    [$game_map.map_id, p.x, p.y, p.direction, p.pattern, gv(p, :@move_speed),
     p.dash? ? true : false, p.character_name, p.character_index, p.transparent ? true : false,
     p.opacity, p.moving? ? true : false]
  end

  def self.ev_state(e)
    [e.x, e.y, e.direction, (e.moving? ? -1 : e.pattern), e.character_name, e.character_index,
     e.opacity, e.blend_type, e.transparent ? true : false, gv(e, :@erased) ? true : false,
     gv(e, :@move_speed), e.through ? true : false, e.priority_type, e.tile_id,
     gv(e, :@step_anime) ? true : false, gv(e, :@walk_anime) ? true : false,
     gv(e, :@direction_fix) ? true : false, gv(e, :@jump_count) || 0, gv(e, :@jump_peak) || 0,
     e.trigger]
  end

  def self.all_event_states
    list = []
    $game_map.events.each { |id, e| list << ([id] + ev_state(e)) }
    list
  end

  def self.host_tick
    @tick += 1
    host_catch_checks
    st = local_state
    if st != @pstates[0]
      @pstates[0] = st
      @ps_dirty = true
    end
    if @tick % 2 == 0
      if @ps_dirty
        broadcast([:ps, @pstates])
        @ps_dirty = false
      end
      host_send_events
    end
    host_send_screen if @tick % 3 == 0
    host_send_vars if @tick % 30 == 0
  rescue Exception => e
    log_error("host_tick", e)
  end

  def self.host_send_events
    mid = $game_map.map_id
    if @ev_map != mid
      @ev_map = mid
      @ev_last = {}
    end
    diffs = []
    $game_map.events.each do |id, e|
      s = ev_state(e)
      if @ev_last[id] != s
        @ev_last[id] = s
        diffs << ([id] + s)
      end
    end
    broadcast([:ev, mid, diffs]) unless diffs.empty?
  end

  # Serialize an object's simple instance variables (Tone/Color as tagged arrays).
  def self.snap_obj(o, skip)
    h = {}
    o.instance_variables.each do |n|
      n = n.to_s
      next if skip && skip.include?(n)
      v = o.instance_variable_get(n)
      if v.is_a?(Tone)
        v = [:T, v.red, v.green, v.blue, v.gray]
      elsif v.is_a?(Color)
        v = [:C, v.red, v.green, v.blue, v.alpha]
      elsif !(v.is_a?(Numeric) || v.is_a?(String) || v == true || v == false || v.nil?)
        next
      end
      h[n] = v
    end
    h
  end

  def self.unwrap(v)
    if v.is_a?(Array) && v[0] == :T
      Tone.new(v[1], v[2], v[3], v[4])
    elsif v.is_a?(Array) && v[0] == :C
      Color.new(v[1], v[2], v[3], v[4])
    else
      v
    end
  end

  def self.obj_apply(o, h)
    h.each { |k, v| o.instance_variable_set(k, unwrap(v)) }
  end

  SCREEN_SKIP = ["@pictures"]

  def self.screen_full
    s = $game_map.screen
    pics = {}
    s.pictures.each_with_index { |p, i| pics[i] = snap_obj(p, nil) if p }
    [snap_obj(s, SCREEN_SKIP), pics]
  end

  def self.host_send_screen
    s = $game_map.screen
    sh = snap_obj(s, SCREEN_SKIP)
    out_sh = nil
    if sh != @scr_last
      @scr_last = sh
      out_sh = sh
    end
    pics = {}
    s.pictures.each_with_index do |p, i|
      next unless p
      h = snap_obj(p, nil)
      if @pic_last[i] != h
        @pic_last[i] = h
        pics[i] = h
      end
    end
    broadcast([:screen, out_sh, pics]) if out_sh || !pics.empty?
  end

  def self.vars_snapshot
    gp = $game_party
    actors = gv(gp, :@actors) || []
    looks = []
    actors.each do |id|
      a = $game_actors[id]
      next unless a
      looks << [id, a.name, a.character_name, a.character_index, a.face_name, a.face_index]
    end
    party = [gp.gold, gv(gp, :@items), gv(gp, :@weapons), gv(gp, :@armors), actors, looks]
    [gv($game_switches, :@data), gv($game_variables, :@data), gv($game_self_switches, :@data), party]
  end

  def self.host_send_vars
    v = vars_snapshot
    d = Pack.dump(v)
    return if d == @vars_last
    @vars_last = d
    broadcast([:vars, v])
  end

  # --- enemies -------------------------------------------------------------
  def self.chaser?(e)
    return false unless e.is_a?(Game_Event)
    return false if gv(e, :@erased)
    t = e.trigger
    return false unless t == 1 || t == 2
    return false unless e.priority_type == 1
    page = gv(e, :@page)
    return false if page.nil?
    key = page.object_id
    r = @chaser_pages[key]
    return r unless r.nil?
    mt = gv(e, :@move_type)
    ok = (mt == 2)
    if mt == 3 && page.move_route
      ok = page.move_route.list.any? { |c| c.code == 10 }
    end
    list = e.list || []
    if ok
      ok = list.all? { |c| ENEMY_CODES.include?(c.code) } &&
           list.any? { |c| c.code == 123 || c.code == 121 }
    end
    @chaser_pages[key] = ok
    ok
  end

  def self.target_for(e)
    return nil unless host? && e.is_a?(Game_Event)
    return nil unless chaser?(e)
    t = gv(e, :@coop_tgt)
    tt = gv(e, :@coop_tgt_t) || -999
    if t && Graphics.frame_count - tt < 12 && target_alive?(t)
      return t
    end
    best = nil
    bd = 999999
    cands = []
    cands << $game_player unless @downed[0]
    @chars.each do |pid, ch|
      cands << ch if !@downed[pid] && ch.net_map == $game_map.map_id
    end
    cands.each do |c|
      d = (c.x - e.x).abs + (c.y - e.y).abs
      if d < bd
        bd = d
        best = c
      end
    end
    sv(e, :@coop_tgt, best)
    sv(e, :@coop_tgt_t, Graphics.frame_count)
    best
  end

  def self.target_alive?(t)
    return !@downed[0] if t.equal?($game_player)
    t.is_a?(Game_CoopPlayer) && @chars[t.pid].equal?(t) && !@downed[t.pid] &&
      t.net_map == $game_map.map_id
  end

  def self.host_catch_checks
    if @gameover
      # the capture scene is over but we're still on the map (no game over screen): regroup
      @go_idle = $game_map.interpreter.running? ? 0 : (@go_idle || 0) + 1
      if @go_idle > 90
        @gameover = false
        @go_idle = 0
        @downed = {}
        broadcast([:down, @downed])
        refresh_local_look
      end
      return
    end
    if @tick % 10 == 0 || @chaser_map != $game_map.map_id
      @chaser_map = $game_map.map_id
      @chaser_list = []
      $game_map.events.each_value { |e| @chaser_list << e if chaser?(e) }
    end
    return if @chaser_list.empty?
    return if $game_map.interpreter.running?
    @chars.each do |pid, ch|
      next if @downed[pid] || ch.net_map != $game_map.map_id
      @chaser_list.each do |e|
        next unless chaser?(e)
        if e.x == ch.x && e.y == ch.y
          host_catch(pid, e)
          break
        end
      end
    end
  end

  # Returns true when the catch was fully handled (vanilla start must not run).
  def self.host_catch(pid, e)
    return true if @gameover || @downed[pid]
    others = @names.keys.select { |q| q != pid && !@downed[q] }
    if others.empty?
      @gameover = true
      toast("Everyone has been caught...")
      broadcast([:toast, "Everyone has been caught..."])
      if pid != 0
        ch = @chars[pid]
        @downed.delete(0)
        refresh_local_look
        $game_player.moveto(ch.x, ch.y) if ch
      end
      e.coop_real_start
      return true
    end
    @downed[pid] = [e.character_name, e.character_index]
    broadcast([:down, @downed])
    msg = "#{@names[pid]} was caught! (#{others.size} left)"
    toast(msg)
    broadcast([:toast, msg])
    refresh_local_look
    true
  end

  def self.host_revive(pid, by)
    return unless @downed[pid] && !@downed[by]
    a = (by == 0) ? $game_player : @chars[by]
    b = (pid == 0) ? $game_player : @chars[pid]
    return unless a && b
    return if (a.x - b.x).abs + (a.y - b.y).abs > 2
    @downed.delete(pid)
    broadcast([:down, @downed])
    msg = "#{@names[by]} revived #{@names[pid]}!"
    toast(msg)
    broadcast([:toast, msg])
    refresh_local_look
  end

  def self.host_net_start(pid, eid, kind)
    return if pid < 0 || @downed[pid] || @gameover
    e = $game_map.events[eid]
    ch = @chars[pid]
    return if e.nil? || ch.nil? || ch.net_map != $game_map.map_id
    return if (e.x - ch.x).abs + (e.y - ch.y).abs > 3
    if chaser?(e)
      host_catch(pid, e)
      return
    end
    return if $game_map.interpreter.running?
    t = e.trigger
    ok = (kind == :action) ? [0, 1, 2].include?(t) : [1, 2].include?(t)
    return unless ok
    log("P#{pid + 1} starts event #{eid} (#{kind})")
    e.coop_real_start
  end

  def self.on_local_transfer
    if host?
      @downed = {} unless @gameover
      refresh_local_look
      @ev_map = nil
      @chaser_pages = {}
      broadcast([:down, @downed])
      broadcast([:map, $game_map.map_id, $game_player.x, $game_player.y, $game_player.direction])
    elsif client?
      @applied_map = nil
      @replay_audio = true   # after the map's own autoplay
    end
  end

  # --- mirrored presentation ---------------------------------------------
  def self.host_msg_started
    @msg_seq += 1
    gm = $game_message
    digits = gm.num_input_variable_id > 0 ? gm.num_input_digits_max : 0
    broadcast([:msg, @msg_seq, gm.texts.dup, gm.face_name, gm.face_index, gm.background,
               gm.position, gm.choice_start, gm.choice_max, digits])
  end

  def self.host_msgkey(index)
    broadcast([:msgkey, @msg_seq, index])
  end

  def self.host_anim(kind, char_id, value)
    broadcast([:anim, kind, char_id, value])
  end

  def self.audio_out(m)
    return unless active?
    return if @audio_mute || @sys_se > 0
    if host?
      case m[0]
      when :bgm then @host_bgm = m
      when :bgm_stop then @host_bgm = nil
      when :bgs then @host_bgs = m
      when :bgs_stop then @host_bgs = nil
      end
      broadcast([:audio] + m)
    end
  end

  def self.sys_se
    @sys_se += 1
    yield
  ensure
    @sys_se -= 1
  end

  def self.on_gameover_scene
    if host?
      broadcast([:gameover])
      @conns.each { |c| c.ready = false }
      @downed = {}
      @gameover = false
    end
  end

  def self.on_title_scene
    if host?
      broadcast([:title])
      @conns.each { |c| c.ready = false }
      @downed = {}
      @gameover = false
    end
  end

  #--------------------------------------------------------------------------
  # CLIENT side
  #--------------------------------------------------------------------------
  def self.client_check_connecting
    s, t0, label = @connecting
    w = [1, s].pack("LL")
    x = [1, s].pack("LL")
    n = WS::Select.call(0, nil, w, x, [0, 0].pack("ll"))
    if n > 0 && w.unpack("L")[0] > 0
      @connecting = nil
      @server = Conn.new(s)
      @server.send_msg([:hello, my_name, VERSION])
      @status = "Connected to #{label}, handshaking..."
      log("connected to #{label}")
    elsif (n > 0 && x.unpack("L")[0] > 0) || Graphics.frame_count - t0 > 60 * 8
      WS::Close.call(s)
      @connecting = nil
      stop("Could not connect to #{label}")
    end
  end

  def self.client_lost
    in_world = @in_world
    stop("Lost connection to the host")
    $scene = Scene_Title.new if in_world
  end

  def self.client_recv(m)
    case m[0]
    when :welcome
      @me = m[1]
      @names = m[2]
      @status = "Joined as P#{@me + 1}. Waiting for the host to enter the game..."
      toast("Joined as P#{@me + 1}")
    when :reject
      stop(m[1])
    when :names
      @names = m[1]
    when :world
      @pending_world = m[1]
    when :map
      @pending_map = m[1, 4]
    when :ev
      if m[1] != @host_map
        @host_map = m[1]
        @ev_cache = {}
        @ev_dirty = {}
        @applied_map = nil
      end
      m[2].each do |s|
        @ev_cache[s[0]] = s
        @ev_dirty[s[0]] = true
      end
    when :ps
      m[1].each { |pid, st| @pstates[pid] = st unless pid == @me }
    when :down
      @downed = m[1]
      refresh_local_look if @in_world
    when :screen
      apply_screen(m[1], m[2]) if @in_world
    when :vars
      apply_vars(m[1]) if @in_world
    when :msg
      @msg_queue << m
    when :msgkey
      @msg_keys << [m[1], m[2]]
    when :audio
      client_audio(m[1, m.size - 1])
    when :anim
      client_anim(m[1], m[2], m[3]) if @in_world
    when :toast
      toast(m[1])
    when :gameover
      @goto_scene = :gameover
    when :title
      @goto_scene = :lobby
    when :leave
      @names.delete(m[1])
      @pstates.delete(m[1])
      @chars.delete(m[1])
    when :bye
      client_lost
    end
  end

  def self.client_enter_world
    w = @pending_world
    @pending_world = nil
    @msg_queue = []
    @msg_keys = []
    title = Scene_Title.new
    title.load_database if $data_system.nil?
    title.create_game_objects
    begin
      f = File.open("Audio/lang.txt", "r")
      $game_temp.lang = f.gets.to_s.strip
      f.close
    rescue Exception
      $game_temp.lang = "1"
    end
    $game_party.setup_starting_members
    apply_vars(w["vars"])
    $game_map.setup(w["map"])
    $game_player.moveto(w["x"], w["y"])
    sv($game_player, :@direction, w["dir"])
    @names = w["names"]
    w["ps"].each { |pid, st| @pstates[pid] = st unless pid == @me }
    @downed = w["down"]
    @in_world = true
    $game_player.refresh
    apply_screen(w["screen"][0], w["screen"][1])
    @host_bgm = w["bgm"]
    @host_bgs = w["bgs"]
    play_host_audio
    @status = "In game as P#{@me + 1}"
    $scene = Scene_Map.new
    log("entered world map #{w['map']} at #{w['x']},#{w['y']}")
  end

  def self.client_tick
    @tick += 1
    if @goto_scene
      g = @goto_scene
      @goto_scene = nil
      @in_world = false
      @msg_queue = []
      @msg_keys = []
      $scene = (g == :gameover) ? Scene_Gameover.new : Scene_Coop.new
      return
    end
    if @pending_world
      w = @pending_world
      @pending_world = nil
      apply_vars(w["vars"])
      @names = w["names"]
      @downed = w["down"]
      refresh_local_look
      apply_screen(w["screen"][0], w["screen"][1])
      if $game_map.map_id != w["map"]
        $game_player.reserve_transfer(w["map"], w["x"], w["y"], w["dir"])
      end
      @applied_map = nil
    end
    if @pending_map && !$game_player.transfer?
      mid, x, y, d = @pending_map
      @pending_map = nil
      $game_player.reserve_transfer(mid, x, y, d)
    end
    if @replay_audio && !$game_player.transfer?
      @replay_audio = false
      play_host_audio
    end
    client_apply_events
    client_feed_messages
    if @tick % 2 == 0
      st = local_state
      if st != @last_me
        @last_me = st
        @server.send_msg([:me, st]) if @server
      end
    end
  rescue Exception => e
    log_error("client_tick", e)
  end

  def self.client_apply_events
    return if @host_map.nil? || $game_map.map_id != @host_map || $game_player.transfer?
    if @applied_map != @host_map
      @applied_map = @host_map
      @ev_cache.each_value { |s| apply_ev(s) }
    else
      @ev_dirty.each_key { |id| s = @ev_cache[id]; apply_ev(s) if s }
    end
    @ev_dirty = {}
  end

  def self.apply_ev(s)
    e = $game_map.events[s[0]]
    return unless e
    x, y, dir, pat, cn, ci, op, bl, tr, er, spd, thr, pri, tile, stepa, walka, dfix, jc, jp, trig = s[1, 20]
    cn = localize_char(cn)
    if e.x != x || e.y != y
      $game_map.clear_event_loc(e) if $game_map.emap
      far = ((e.x - x).abs + (e.y - y).abs > 1) && jc == 0
      sv(e, :@x, x)
      sv(e, :@y, y)
      if far
        sv(e, :@real_x, x * 256)
        sv(e, :@real_y, y * 256)
      end
      sv(e, :@stop_count, 0)
      $game_map.set_event_loc(e) if $game_map.emap
    end
    graphic_changed = (e.character_name != cn || e.tile_id != tile)
    sv(e, :@direction, dir)
    sv(e, :@pattern, pat) if pat >= 0 && !e.moving?
    sv(e, :@character_name, cn)
    sv(e, :@character_index, ci)
    sv(e, :@opacity, op)
    sv(e, :@blend_type, bl)
    sv(e, :@transparent, tr)
    sv(e, :@erased, er)
    sv(e, :@move_speed, spd)
    sv(e, :@through, thr)
    sv(e, :@priority_type, pri)
    sv(e, :@tile_id, tile)
    sv(e, :@step_anime, stepa)
    sv(e, :@walk_anime, walka)
    sv(e, :@direction_fix, dfix)
    sv(e, :@trigger, trig)
    if jc > 0 && (gv(e, :@jump_count) || 0) == 0
      sv(e, :@jump_count, jc)
      sv(e, :@jump_peak, jp)
    end
    if graphic_changed && (cn != "" || tile != 0) && e.ignore_sprite
      e.clear_antilag_flags
      $scene.create_event_sprite(e) if $scene.is_a?(Scene_Map)
    end
  end

  def self.apply_screen(sh, pics)
    return unless $game_map
    s = $game_map.screen
    obj_apply(s, sh) if sh
    return unless pics
    pics.each do |i, h|
      p = s.pictures[i]
      next unless p
      if h["@name"]
        h = h.dup
        h["@name"] = localize_pic(h["@name"])
      end
      obj_apply(p, h)
    end
  end

  def self.apply_vars(v)
    return unless v
    sw, va, ss, party = v
    sv($game_switches, :@data, sw) if sw
    sv($game_variables, :@data, va) if va
    sv($game_self_switches, :@data, ss) if ss
    return unless party
    gold, items, weapons, armors, actors, looks = party
    gp = $game_party
    sv(gp, :@gold, gold)
    sv(gp, :@items, items) if items
    sv(gp, :@weapons, weapons) if weapons
    sv(gp, :@armors, armors) if armors
    sv(gp, :@actors, actors) if actors
    (looks || []).each do |id, nm, cn, ci, fn, fi|
      a = $game_actors[id]
      next unless a
      sv(a, :@name, nm)
      a.set_graphic(cn, ci, fn, fi)
    end
    $game_player.refresh if $game_player
  end

  def self.client_feed_messages
    return unless $game_message.texts.empty?
    return if @msg_queue.empty?
    m = @msg_queue.shift
    @cur_seq = m[1]
    gm = $game_message
    gm.texts = m[2].dup
    gm.face_name = m[3]
    gm.face_index = m[4]
    gm.background = m[5]
    gm.position = m[6]
    gm.choice_start = m[7]
    gm.choice_max = m[8]
    gm.choice_cancel_type = 0
    gm.num_input_variable_id = m[9] > 0 ? 1 : 0
    gm.num_input_digits_max = m[9]
  end

  def self.msgkey_pending?
    @msg_keys.any? { |k| k[0] == @cur_seq }
  end

  def self.take_msgkey
    @msg_keys.shift while !@msg_keys.empty? && @msg_keys[0][0] < @cur_seq
    return nil if @msg_keys.empty? || @msg_keys[0][0] != @cur_seq
    @msg_keys.shift
  end

  def self.client_audio(m)
    @audio_mute = true
    case m[0]
    when :bgm then @host_bgm = m; RPG::BGM.new(m[1], m[2], m[3]).play
    when :bgm_stop then @host_bgm = nil; RPG::BGM.stop
    when :bgm_fade then RPG::BGM.fade(m[1])
    when :bgs then @host_bgs = m; RPG::BGS.new(m[1], m[2], m[3]).play
    when :bgs_stop then @host_bgs = nil; RPG::BGS.stop
    when :bgs_fade then RPG::BGS.fade(m[1])
    when :me then RPG::ME.new(m[1], m[2], m[3]).play
    when :me_stop then RPG::ME.stop
    when :se then RPG::SE.new(m[1], m[2], m[3]).play
    end
  rescue Exception => e
    log_error("audio", e)
  ensure
    @audio_mute = false
  end

  def self.play_host_audio
    @audio_mute = true
    if @host_bgm then RPG::BGM.new(@host_bgm[1], @host_bgm[2], @host_bgm[3]).play end
    if @host_bgs then RPG::BGS.new(@host_bgs[1], @host_bgs[2], @host_bgs[3]).play end
  rescue Exception
  ensure
    @audio_mute = false
  end

  def self.client_anim(kind, char_id, value)
    c = (char_id == -1) ? @chars[0] : $game_map.events[char_id]
    return unless c
    if kind == :anim
      c.animation_id = value
    else
      c.balloon_id = value
    end
    if c.is_a?(Game_Event) && c.ignore_sprite
      c.clear_antilag_flags
      $scene.create_event_sprite(c) if $scene.is_a?(Scene_Map)
    end
  end

  def self.client_forward_start(e)
    return if local_downed? || @server.nil?
    last = @fwd_cool[e.id] || -999
    return if Graphics.frame_count - last < 30
    @fwd_cool[e.id] = Graphics.frame_count
    @server.send_msg([:start, e.id, @fwd_kind || :touch])
  end

  #--------------------------------------------------------------------------
  # Both sides: remote player characters, looks, revive
  #--------------------------------------------------------------------------
  def self.update_chars
    @pstates.each do |pid, st|
      next if pid == @me
      ch = (@chars[pid] ||= Game_CoopPlayer.new(pid))
      ch.apply(st, @downed[pid])
      ch.update
    end
    @chars.keys.each { |pid| @chars.delete(pid) unless @pstates[pid] && pid != @me }
  end

  def self.visible_chars
    h = {}
    return h unless $game_map
    @chars.each { |pid, ch| h[pid] = ch if ch.net_map == $game_map.map_id }
    h
  end

  def self.refresh_local_look
    $game_player.refresh if $game_player && $game_party
  end

  def self.decorate_local_player
    p = $game_player
    look = active? ? @downed[@me] : nil
    if look
      sv(p, :@character_name, localize_char(look[0]))
      sv(p, :@character_index, look[1])
      sv(p, :@opacity, 120)
      sv(p, :@through, true)
      @ghost = true
    elsif @ghost
      sv(p, :@opacity, 255)
      sv(p, :@through, false)
      @ghost = false
    end
  end

  def self.try_revive_nearby
    return false if local_downed?
    p = $game_player
    @chars.each do |pid, ch|
      next unless @downed[pid] && ch.net_map == $game_map.map_id
      next if (ch.x - p.x).abs + (ch.y - p.y).abs > 1
      if host?
        host_revive(pid, 0)
      elsif @server
        @server.send_msg([:revive, pid])
      end
      return true
    end
    false
  end

  def self.localize_char(n)
    return n unless n.is_a?(String) && n[0, 2] == "$!"
    base = n.sub(/_\d+\z/, "")
    return n unless LOC_CHARS.include?(base)
    lang = ($game_temp && $game_temp.lang).to_s
    (lang == "1" || lang == "") ? base : base + "_" + lang
  end

  def self.localize_pic(n)
    if n.is_a?(String) && n =~ /\A(67|68)(_\d+)?\z/
      $1 + "_" + ($game_temp && $game_temp.lang).to_s
    else
      n
    end
  end

  def self.tone_for(pid)
    t = TINTS[pid % TINTS.size] if pid && pid >= 0
    t ? Tone.new(t[0], t[1], t[2], t[3]) : Tone.new(0, 0, 0, 0)
  end

  def self.color_for(pid)
    c = NAME_COLORS[(pid || 0) % NAME_COLORS.size]
    Color.new(c[0], c[1], c[2])
  end

  def self.plate_text(pid)
    n = @names[pid] || "P#{pid + 1}"
    @downed[pid] ? "#{n} (caught)" : n
  end

  #--------------------------------------------------------------------------
  # Overlay (status line, player list, toasts) — lives above every scene
  #--------------------------------------------------------------------------
  def self.overlay_update
    if @overlay.nil? || @overlay.disposed?
      @overlay = Sprite.new
      @overlay.bitmap = Bitmap.new(544, 140)
      @overlay.z = 10000
      @overlay_dirty = true
    end
    @overlay.visible = active? || !@toasts.empty?
    return unless @overlay.visible
    before = @toasts.size
    @toasts.each { |t| t[1] -= 1 }
    @toasts = @toasts.select { |t| t[1] > 0 }
    @overlay_dirty = true if @toasts.size != before
    sig = [@mode, @names.size, @downed.size, @status, @toasts.size, @in_world]
    @overlay_dirty = true if sig != @overlay_sig
    @overlay_sig = sig
    return unless @overlay_dirty
    @overlay_dirty = false
    b = @overlay.bitmap
    b.clear
    b.font.size = 15
    b.font.shadow = true
    if active?
      b.font.color = Color.new(255, 255, 255)
      label = host? ? "CO-OP HOST" : (@me >= 0 ? "CO-OP P#{@me + 1}" : "CO-OP")
      b.draw_text(6, 2, 200, 18, label)
      y = 2
      @names.keys.sort.each do |pid|
        b.font.color = @downed[pid] ? Color.new(255, 90, 90) : color_for(pid)
        b.draw_text(300, y, 238, 18, "P#{pid + 1} " + plate_text(pid), 2)
        y += 16
      end
    end
    y = 40
    @toasts.last(4).each do |t|
      b.font.color = Color.new(255, 230, 140)
      b.draw_text(0, y, 544, 20, t[0], 1)
      y += 20
    end
  end
end

#==============================================================================
# Remote player character + sprite
#==============================================================================
class Game_CoopPlayer < Game_Character
  attr_reader :pid, :net_map

  def initialize(pid)
    super()
    @pid = pid
    @net_map = 0
    @net_dash = false
    @through = true
    @priority_type = 1
    @walk_anime = true
    @placed = false
  end

  def dash?
    @net_dash
  end

  def on_screen
    true
  end

  def apply(st, down)
    map, x, y, dir, pat, spd, dash, cn, ci, tr, op = st
    @net_map = map
    @move_speed = spd || 4
    @net_dash = dash
    @transparent = tr
    if down
      @character_name = Coop.localize_char(down[0])
      @character_index = down[1]
      @opacity = 120
    else
      @character_name = cn
      @character_index = ci
      @opacity = op
    end
    if !@placed || (x - @x).abs + (y - @y).abs > 1
      @x = x
      @y = y
      @real_x = x * 256
      @real_y = y * 256
      @placed = true
    elsif x != @x || y != @y
      @x = x
      @y = y
      @stop_count = 0
    end
    @direction = dir
    @pattern = pat if !moving? && pat
  end

  def update
    if jumping?
      update_jump
    elsif moving?
      update_move
    else
      update_stop
    end
    update_animation
  end
end

class Sprite_CoopPlayer < Sprite_Character
  def initialize(viewport, character)
    @plate = Sprite.new(viewport)
    @plate.bitmap = Bitmap.new(160, 20)
    @plate_text = nil
    super(viewport, character)
  end

  def update
    super
    self.tone = Coop.tone_for(@character.pid)
    txt = Coop.plate_text(@character.pid)
    if txt != @plate_text
      @plate_text = txt
      b = @plate.bitmap
      b.clear
      b.font.size = 14
      b.font.shadow = true
      b.font.color = Coop.downed[@character.pid] ? Color.new(255, 110, 110) : Coop.color_for(@character.pid)
      b.draw_text(0, 0, 160, 20, txt, 1)
    end
    @plate.x = self.x - 80
    @plate.y = self.y - (@ch || 32) - 16
    @plate.z = 300
    @plate.visible = self.visible && !@character.transparent
  end

  def dispose
    @plate.bitmap.dispose
    @plate.dispose
    super
  end
end

#==============================================================================
# Hooks: graphics pump
#==============================================================================
class << Graphics
  alias_method :coop_update, :update unless method_defined?(:coop_update)
  def update
    coop_update
    Coop.pump
  end
end

#==============================================================================
# Hooks: characters / events / player
#==============================================================================
class Game_Character
  alias_method :coop_dxp, :distance_x_from_player unless Coop.hooked?(self, :coop_dxp)
  alias_method :coop_dyp, :distance_y_from_player unless Coop.hooked?(self, :coop_dyp)
  alias_method :coop_mttp, :move_type_toward_player unless Coop.hooked?(self, :coop_mttp)

  def distance_x_from_player
    t = Coop.host? ? Coop.target_for(self) : nil
    return coop_dxp if t.nil? || t.equal?($game_player)
    @x - t.x
  end

  def distance_y_from_player
    t = Coop.host? ? Coop.target_for(self) : nil
    return coop_dyp if t.nil? || t.equal?($game_player)
    @y - t.y
  end

  def move_type_toward_player
    return coop_mttp unless Coop.host?
    sx = distance_x_from_player
    sy = distance_y_from_player
    if sx.abs + sy.abs >= 20
      move_random
    else
      case rand(6)
      when 0..3 then move_toward_player
      when 4 then move_random
      when 5 then move_forward
      end
    end
  end
end

class Game_Event < Game_Character
  alias_method :coop_start, :start unless Coop.hooked?(self, :coop_start)
  alias_method :coop_ev_update, :update unless Coop.hooked?(self, :coop_ev_update)
  alias_method :coop_ev_refresh, :refresh unless Coop.hooked?(self, :coop_ev_refresh)
  alias_method :coop_ev_init, :initialize unless Coop.hooked?(self, :coop_ev_init)
  alias_method :coop_cett, :check_event_trigger_touch unless Coop.hooked?(self, :coop_cett)

  def initialize(map_id, event)
    coop_ev_init(map_id, event)
    @coop_inited = true
  end

  def coop_real_start
    coop_start
  end

  def start
    if Coop.host? && Coop.chaser?(self)
      return if Coop.local_downed?
      Coop.host_catch(0, self)
      return
    elsif Coop.client?
      Coop.client_forward_start(self)
      return
    end
    coop_start
  end

  def update
    if Coop.client?
      if jumping?
        update_jump
      elsif moving?
        update_move
      else
        update_stop
      end
      update_animation
      return
    end
    coop_ev_update
  end

  def refresh
    return if Coop.client? && @coop_inited
    coop_ev_refresh
  end

  def check_event_trigger_touch(x, y)
    return if Coop.host? && Coop.local_downed?
    coop_cett(x, y)
  end
end

class Game_Player < Game_Character
  alias_method :coop_refresh, :refresh unless Coop.hooked?(self, :coop_refresh)
  alias_method :coop_passable?, :passable? unless Coop.hooked?(self, :coop_passable?)
  alias_method :coop_update_nonmoving, :update_nonmoving unless Coop.hooked?(self, :coop_update_nonmoving)
  alias_method :coop_ceth, :check_event_trigger_here unless Coop.hooked?(self, :coop_ceth)
  alias_method :coop_cettr, :check_event_trigger_there unless Coop.hooked?(self, :coop_cettr)
  alias_method :coop_cet, :check_event_trigger_touch unless Coop.hooked?(self, :coop_cet)
  alias_method :coop_perform_transfer, :perform_transfer unless Coop.hooked?(self, :coop_perform_transfer)

  def refresh
    coop_refresh
    Coop.decorate_local_player
  end

  def passable?(x, y)
    if Coop.local_downed?
      x = $game_map.round_x(x)
      y = $game_map.round_y(y)
      return false unless $game_map.valid?(x, y)
      return map_passable?(x, y)
    end
    coop_passable?(x, y)
  end

  def update_nonmoving(last_moving)
    if Coop.active?
      return if Coop.local_downed?
      if !moving? && !$game_message.visible && Input.trigger?(Input::C)
        return if Coop.try_revive_nearby
      end
    end
    coop_update_nonmoving(last_moving)
  end

  def check_event_trigger_here(triggers)
    return false if Coop.local_downed?
    Coop.fwd_kind = triggers.include?(0) ? :action : :touch
    coop_ceth(triggers)
  end

  def check_event_trigger_there(triggers)
    return false if Coop.local_downed?
    Coop.fwd_kind = :action
    coop_cettr(triggers)
  end

  def check_event_trigger_touch(x, y)
    return false if Coop.local_downed?
    Coop.fwd_kind = :touch
    coop_cet(x, y)
  end

  def perform_transfer
    was = @transferring
    coop_perform_transfer
    Coop.on_local_transfer if was
  end
end

class Game_Map
  alias_method :coop_update_events, :update_events unless Coop.hooked?(self, :coop_update_events)
  def update_events
    if Coop.client?
      for event in @events.values
        event.update
      end
      return
    end
    coop_update_events
  end
end

#==============================================================================
# Hooks: interpreter (animations/balloons), messages, audio
#==============================================================================
class Game_Interpreter
  alias_method :coop_command_212, :command_212 unless Coop.hooked?(self, :coop_command_212)
  alias_method :coop_command_213, :command_213 unless Coop.hooked?(self, :coop_command_213)

  def command_212
    r = coop_command_212
    if Coop.host?
      id = @params[0] == 0 ? @event_id : @params[0]
      Coop.host_anim(:anim, id, @params[1])
    end
    r
  end

  def command_213
    r = coop_command_213
    if Coop.host?
      id = @params[0] == 0 ? @event_id : @params[0]
      Coop.host_anim(:balloon, id, @params[1])
    end
    r
  end
end

class Window_Message < Window_Selectable
  alias_method :coop_start_message, :start_message unless Coop.hooked?(self, :coop_start_message)
  alias_method :coop_input_pause, :input_pause unless Coop.hooked?(self, :coop_input_pause)
  alias_method :coop_input_choice, :input_choice unless Coop.hooked?(self, :coop_input_choice)
  alias_method :coop_input_number, :input_number unless Coop.hooked?(self, :coop_input_number)
  alias_method :coop_update_show_fast, :update_show_fast unless Coop.hooked?(self, :coop_update_show_fast)

  def start_message
    Coop.host_msg_started if Coop.host?
    coop_start_message
  end

  def input_pause
    unless Coop.client?
      was = self.pause
      coop_input_pause
      Coop.host_msgkey(-1) if Coop.host? && was && !self.pause
      return
    end
    return unless Coop.take_msgkey
    self.pause = false
    if @text != nil and not @text.empty?
      new_page if @line_count >= MAX_LINE
    else
      terminate_message
    end
  end

  def input_choice
    unless Coop.client?
      idx = self.index
      coop_input_choice
      Coop.host_msgkey(idx) if Coop.host? && !self.active
      return
    end
    k = Coop.take_msgkey
    return unless k
    self.index = k[1] if k[1] && k[1] >= 0
    terminate_message
  end

  def input_number
    unless Coop.client?
      coop_input_number
      Coop.host_msgkey(-1) if Coop.host? && !@number_input_window.active
      return
    end
    return unless Coop.take_msgkey
    terminate_message
  end

  def update_show_fast
    if Coop.client? && Coop.msgkey_pending?
      @show_fast = true
      @wait_count = 0 if @wait_count > 1 && !self.pause
      return
    end
    coop_update_show_fast
  end
end

module RPG
  class BGM < AudioFile
    alias_method :coop_play, :play unless method_defined?(:coop_play)
    def play
      coop_play
      Coop.audio_out(@name.empty? ? [:bgm_stop] : [:bgm, @name, @volume, @pitch])
    end
    class << self
      alias_method :coop_stop, :stop unless method_defined?(:coop_stop)
      alias_method :coop_fade, :fade unless method_defined?(:coop_fade)
      def stop
        coop_stop
        Coop.audio_out([:bgm_stop])
      end
      def fade(time)
        coop_fade(time)
        Coop.audio_out([:bgm_fade, time])
      end
    end
  end

  class BGS < AudioFile
    alias_method :coop_play, :play unless method_defined?(:coop_play)
    def play
      coop_play
      Coop.audio_out(@name.empty? ? [:bgs_stop] : [:bgs, @name, @volume, @pitch])
    end
    class << self
      alias_method :coop_stop, :stop unless method_defined?(:coop_stop)
      alias_method :coop_fade, :fade unless method_defined?(:coop_fade)
      def stop
        coop_stop
        Coop.audio_out([:bgs_stop])
      end
      def fade(time)
        coop_fade(time)
        Coop.audio_out([:bgs_fade, time])
      end
    end
  end

  class ME < AudioFile
    alias_method :coop_play, :play unless method_defined?(:coop_play)
    def play
      coop_play
      Coop.audio_out([:me, @name, @volume, @pitch]) unless @name.empty?
    end
  end

  class SE < AudioFile
    alias_method :coop_play, :play unless method_defined?(:coop_play)
    def play
      coop_play
      Coop.audio_out([:se, @name, @volume, @pitch]) unless @name.empty?
    end
  end
end

# System sounds (cursor, decision, ...) stay local.
Sound.singleton_methods(false).each do |name|
  name = name.to_s
  next unless name =~ /\Aplay_/
  next if Sound.respond_to?("coop_#{name}")
  Sound.module_eval("class << self; alias_method :coop_#{name}, :#{name}; " +
                    "def #{name}(*a); Coop.sys_se { coop_#{name}(*a) }; end; end")
end

#==============================================================================
# Hooks: scenes
#==============================================================================
class Spriteset_Map
  alias_method :coop_update_characters, :update_characters unless Coop.hooked?(self, :coop_update_characters)
  alias_method :coop_dispose_characters, :dispose_characters unless Coop.hooked?(self, :coop_dispose_characters)

  def update_characters
    coop_update_characters
    coop_sync_sprites
  end

  def coop_sync_sprites
    @coop_sprites ||= {}
    want = Coop.active? ? Coop.visible_chars : {}
    @coop_sprites.keys.each do |pid|
      s = @coop_sprites[pid]
      unless want[pid] && s.character.equal?(want[pid])
        s.dispose
        @coop_sprites.delete(pid)
      end
    end
    want.each do |pid, ch|
      s = (@coop_sprites[pid] ||= Sprite_CoopPlayer.new(@viewport1, ch))
      s.update
    end
    unless @coop_player_sprite
      @character_sprites.each { |s| @coop_player_sprite = s if s.character.equal?($game_player) }
    end
    if @coop_player_sprite
      @coop_player_sprite.tone = Coop.active? ? Coop.tone_for(Coop.me) : Tone.new(0, 0, 0, 0)
    end
  end

  def dispose_characters
    coop_dispose_characters
    (@coop_sprites || {}).each_value { |s| s.dispose }
    @coop_sprites = {}
  end
end

class Scene_Map < Scene_Base
  alias_method :coop_map_start, :start unless Coop.hooked?(self, :coop_map_start)
  alias_method :coop_map_update, :update unless Coop.hooked?(self, :coop_map_update)

  def start
    coop_map_start
    Coop.on_map_scene_start
  end

  def update
    unless Coop.client?
      coop_map_update
      if Coop.host?
        Coop.update_chars
        Coop.host_tick
      end
      return
    end
    $game_map.update
    $game_player.update
    $game_system.update
    Coop.update_chars
    @spriteset.update
    @message_window.update
    Coop.client_tick
    return if $scene != self
    unless $game_message.visible
      update_transfer_player
      update_call_menu
      update_scene_change
    end
  end
end

class Scene_File < Scene_Base
  alias_method :coop_do_save, :do_save unless Coop.hooked?(self, :coop_do_save)
  alias_method :coop_do_load, :do_load unless Coop.hooked?(self, :coop_do_load)

  def do_save
    if Coop.client?
      Sound.play_buzzer
      Coop.toast("Only the host can save")
      return
    end
    coop_do_save
  end

  def do_load
    if Coop.client?
      Sound.play_buzzer
      Coop.toast("Clients can't load: the host's game is used")
      return
    end
    coop_do_load
  end
end

class Scene_Gameover < Scene_Base
  alias_method :coop_go_start, :start unless Coop.hooked?(self, :coop_go_start)
  alias_method :coop_go_update, :update unless Coop.hooked?(self, :coop_go_update)

  def start
    coop_go_start
    Coop.on_gameover_scene
  end

  def update
    if Coop.client? && Input.trigger?(Input::C)
      $scene = Scene_Coop.new
      return
    end
    coop_go_update
  end
end

class Scene_Title < Scene_Base
  alias_method :coop_title_start, :start unless Coop.hooked?(self, :coop_title_start)
  alias_method :coop_title_update, :update unless Coop.hooked?(self, :coop_title_update)
  alias_method :coop_create_command_window, :create_command_window unless Coop.hooked?(self, :coop_create_command_window)

  def start
    coop_title_start
    Coop.on_title_scene
  end

  def create_command_window
    coop_create_command_window
    cmds = @command_window.commands + [Coop.active? ? "CO-OP (online)" : "CO-OP"]
    idx = @command_window.index
    @command_window.dispose
    @command_window = Window_Command.new(172, cmds)
    @command_window.x = (544 - @command_window.width) / 2
    @command_window.y = [224, 416 - @command_window.height].min
    @command_window.index = idx
    @command_window.draw_item(1, false) unless @continue_enabled
    @command_window.openness = 0
    @command_window.open
  end

  def update
    if Coop.client? && Input.trigger?(Input::C) && [0, 1].include?(@command_window.index)
      Sound.play_buzzer
      Coop.toast("You joined a co-op game: the host picks New Game / Continue")
      return
    end
    coop_title_update
    if $scene == self && Input.trigger?(Input::C) && @command_window.index == @command_window.commands.size - 1
      Sound.play_decision
      $scene = Scene_Coop.new
    end
  end
end

#==============================================================================
# Co-op menu: host / join / edit address, port and name
#==============================================================================
class Scene_Coop < Scene_Base
  KeyState = Win32API.new("user32", "GetAsyncKeyState", "i", "i")
  Foreground = Win32API.new("user32", "GetForegroundWindow", "v", "i")
  WinPid = Win32API.new("user32", "GetWindowThreadProcessId", "ip", "i")
  CurPid = Win32API.new("kernel32", "GetCurrentProcessId", "v", "i")

  def start
    super
    create_menu_background
    @help = Window_Help.new
    @help.set_text("Changed Co-op #{Coop::VERSION}  -  2+ players online")
    @cmd = Window_Command.new(272, commands)
    @cmd.x = 16
    @cmd.y = 72
    @info = Window_Base.new(296, 72, 232, 328)
    @editing = nil
    @keys = {}
    refresh_info
  end

  def terminate
    super
    dispose_menu_background
    @help.dispose
    @cmd.dispose
    @info.dispose
  end

  def commands
    host = Coop.ini("Host", "127.0.0.1")
    port = Coop.ini("Port", "27500")
    [Coop.host? ? "Hosting... (back to title)" : "Host game",
     "Join game",
     "Address: #{host}",
     "Port: #{port}",
     "Name: #{Coop.my_name}",
     Coop.active? ? "Disconnect" : "Back"]
  end

  def rebuild
    idx = @cmd.index
    @cmd.dispose
    @cmd = Window_Command.new(272, commands)
    @cmd.x = 16
    @cmd.y = 72
    @cmd.index = idx
  end

  def refresh_info
    c = @info.contents
    c.clear
    c.font.size = 18
    lines = []
    lines << "Status:"
    lines += wrap(Coop.status || "Offline", 24)
    lines << ""
    if Coop.active?
      lines << "Players:"
      Coop.names.keys.sort.each { |pid| lines << " P#{pid + 1} #{Coop.names[pid]}" }
    else
      lines << "Host: pick Host game,"
      lines << " then New Game/Continue."
      lines << "Friends: set Address to"
      lines << " the host's IP, Join game."
      lines << "Port #{Coop.ini('Port', '27500')} (TCP) must be"
      lines << " reachable on the host."
    end
    y = 0
    lines.each do |l|
      c.draw_text(0, y, 200, 22, l)
      y += 22
    end
    @info_sig = info_sig
  end

  def info_sig
    [Coop.status, Coop.names.size, Coop.mode]
  end

  def wrap(s, n)
    out = []
    s = s.to_s
    while s.size > n
      cut = s.rindex(" ", n) || n
      out << s[0, cut]
      s = s[cut, s.size].to_s.strip
    end
    out << s
  end

  def update
    super
    if @editing
      update_edit
      return
    end
    @cmd.update
    refresh_info if info_sig != @info_sig
    if Input.trigger?(Input::B)
      Sound.play_cancel
      $scene = Scene_Title.new
      return
    end
    return unless Input.trigger?(Input::C)
    case @cmd.index
    when 0
      if Coop.host?
        Sound.play_decision
        $scene = Scene_Title.new
        return
      end
      err = Coop.host_start(Coop.ini("Port", "27500").to_i)
      if err
        Sound.play_buzzer
        Coop.toast(err)
      else
        Sound.play_decision
        $scene = Scene_Title.new
      end
    when 1
      err = Coop.join(Coop.ini("Host", "127.0.0.1"), Coop.ini("Port", "27500").to_i)
      if err
        Sound.play_buzzer
        Coop.toast(err)
      else
        Sound.play_decision
      end
      rebuild
    when 2 then begin_edit("Host", Coop.ini("Host", "127.0.0.1"), 64)
    when 3 then begin_edit("Port", Coop.ini("Port", "27500"), 5)
    when 4 then begin_edit("Name", Coop.my_name, 16)
    when 5
      Sound.play_cancel
      if Coop.active?
        Coop.stop("Disconnected")
        rebuild
      else
        $scene = Scene_Title.new
      end
    end
    refresh_info
  end

  #-- tiny text editor driven by GetAsyncKeyState -------------------------
  def begin_edit(key, value, max)
    Sound.play_decision
    @editing = [key, value.to_s.dup, max]
    @keys = {}
    all_keys.each { |vk| @keys[vk] = true }   # ignore keys already held
    @help.set_text("Type #{key}: #{@editing[1]}_   (Enter = OK, Esc = cancel)")
  end

  def all_keys
    (0x30..0x39).to_a + (0x41..0x5A).to_a + (0x60..0x69).to_a +
      [0x08, 0x0D, 0x1B, 0x20, 0x6E, 0xBA, 0xBD, 0xBE]
  end

  def focused?
    buf = [0].pack("L")
    WinPid.call(Foreground.call, buf)
    buf.unpack("L")[0] == CurPid.call
  end

  def update_edit
    key, text, max = @editing
    shift = (KeyState.call(0x10) & 0x8000) != 0
    pressed = []
    all_keys.each do |vk|
      down = (KeyState.call(vk) & 0x8000) != 0
      pressed << vk if down && !@keys[vk]
      @keys[vk] = down
    end
    return unless focused?
    pressed.each do |vk|
      ch = nil
      if vk >= 0x30 && vk <= 0x39 then ch = (vk - 0x30).to_s
      elsif vk >= 0x60 && vk <= 0x69 then ch = (vk - 0x60).to_s
      elsif vk >= 0x41 && vk <= 0x5A
        ch = (vk.chr)
        ch = ch.downcase unless shift
      elsif vk == 0xBE || vk == 0x6E then ch = "."
      elsif vk == 0xBD then ch = shift ? "_" : "-"
      elsif vk == 0xBA && shift then ch = ":"
      elsif vk == 0x20 && key == "Name" then ch = " "
      elsif vk == 0x08
        text.chop!
      elsif vk == 0x0D
        text = text.strip
        text = text.gsub(/[^0-9]/, "") if key == "Port"
        Coop.set_ini(key, text) unless text.empty?
        Sound.play_decision
        @editing = nil
        @help.set_text("Changed Co-op #{Coop::VERSION}  -  2+ players online")
        rebuild
        refresh_info
        return
      elsif vk == 0x1B
        Sound.play_cancel
        @editing = nil
        @help.set_text("Changed Co-op #{Coop::VERSION}  -  2+ players online")
        return
      end
      if ch && text.size < max
        ch = nil if key == "Port" && ch !~ /\d/
        text << ch if ch
      end
    end
    @editing[1] = text
    @help.set_text("Type #{key}: #{text}_   (Enter = OK, Esc = cancel)")
  end
end

File.open(Coop::DIR + "/coop.log", "w") { |f| f.write("Changed Co-op #{Coop::VERSION} loaded\n") } rescue nil
