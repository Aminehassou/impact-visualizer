namespace :deploy do
  namespace :check do
    before :linked_files, :set_master_key do
      on roles(:app), in: :sequence, wait: 10 do
        unless test("[ -f #{shared_path}/config/master.key ]")
          upload! 'config/master.key', "#{shared_path}/config/master.key"
        end
        unless test("[ -f #{shared_path}/config/credentials/production.key ]")
          upload! 'config/credentials/production.key', "#{shared_path}/config/credentials/production.key"
        end
        unless test("[ -f #{shared_path}/config/credentials/wmcloud.key ]")
          upload! 'config/credentials/wmcloud.key', "#{shared_path}/config/credentials/wmcloud.key"
        end
      end
    end
  end
end
