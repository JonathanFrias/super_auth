require 'rails/generators'

module SuperAuth
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('../templates', __FILE__)

      desc "Creates a SuperAuth initializer"

      def copy_initializer
        template 'super_auth.rb', 'config/initializers/super_auth.rb'
      end

      def show_readme
        readme 'README' if behavior == :invoke
      end
    end
  end
end
