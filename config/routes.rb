require "super_auth/editor"

# The engine serves the graph editor at its mount point. Mount it inside your
# own authentication: it has none of its own.
#
#   authenticate :admin do
#     mount SuperAuth::Engine => "/super_auth"
#   end
SuperAuth::Engine.routes.draw do
  mount SuperAuth::Editor, at: "/"
end
