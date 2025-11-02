SuperAuth::Engine.routes.draw do
  # Main graph visualization interface
  get '/', to: 'graph#index', as: :root
  get '/graph', to: 'graph#index'

  # Graph data API
  get '/graph/data', to: 'graph#data'
  get '/graph/orphaned', to: 'graph#orphaned'
  post '/graph/compile_authorizations', to: 'graph#compile_authorizations'

  # Authorization check
  get '/graph/authorize', to: 'graph#authorize'

  # Legacy visualization endpoint
  get '/visualization', to: 'graph#visualization'

  # CRUD operations for graph entities
  scope :graph do
    resources :users, only: [:create, :destroy], controller: 'graph' do
      collection do
        post '/', action: :create_user
      end
      member do
        delete '/', action: :delete_user
      end
    end

    resources :groups, only: [:create, :destroy], controller: 'graph' do
      collection do
        post '/', action: :create_group
      end
      member do
        delete '/', action: :delete_group
      end
    end

    resources :roles, only: [:create, :destroy], controller: 'graph' do
      collection do
        post '/', action: :create_role
      end
      member do
        delete '/', action: :delete_role
      end
    end

    resources :permissions, only: [:create, :destroy], controller: 'graph' do
      collection do
        post '/', action: :create_permission
      end
      member do
        delete '/', action: :delete_permission
      end
    end

    resources :graph_resources, only: [:create, :destroy], controller: 'graph', path: 'resources' do
      collection do
        post '/', action: :create_resource
      end
      member do
        delete '/', action: :delete_resource
      end
    end

    resources :edges, only: [:create, :destroy], controller: 'graph' do
      collection do
        post '/', action: :create_edge
      end
      member do
        delete '/', action: :delete_edge
      end
    end
  end
end
