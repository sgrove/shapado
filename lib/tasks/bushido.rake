namespace :bushido do
  desc "Bootstrap the Shapado app on the Bushido platform"
  task :install do
    Rake::Task["bootstrap"].invoke
  end

  desc "Run after every code update the Shapado app on the Bushido platform"
  task :update do
    puts "Currently a no-op"
  end
end
