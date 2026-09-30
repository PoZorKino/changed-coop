# Changed Co-op bootstrap.
# Runs the game's own scripts (read from the user's Game.rgss2a through load_data)
# and loads Coop/coop.rb right before Main. Nothing of the game is shipped.
coop_boot_binding = defined?(TOPLEVEL_BINDING) ? TOPLEVEL_BINDING : binding
coop_boot_scripts = load_data("Data/Scripts.rvdata")
coop_boot_scripts.each do |coop_boot_s|
  if coop_boot_s[1] == "Main"
    begin
      coop_boot_code = File.open("Coop/coop.rb", "rb") { |f| f.read }
      eval(coop_boot_code, coop_boot_binding, "coop.rb")
    rescue Exception => coop_boot_e
      File.open("Coop/coop_error.log", "w") do |f|
        f.write("#{coop_boot_e.class}: #{coop_boot_e.message}\n" + (coop_boot_e.backtrace || []).join("\n"))
      end
      print("Changed Co-op failed to load (see Coop/coop_error.log):\n#{coop_boot_e.class}: #{coop_boot_e.message}")
    end
  end
  eval(Zlib::Inflate.inflate(coop_boot_s[2]), coop_boot_binding, coop_boot_s[1])
end
