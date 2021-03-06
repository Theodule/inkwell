module Inkwell
  module ActsAsInkwellUser
    module Base
      def self.included(klass)
        klass.class_eval do
          extend Config
        end
      end
    end

    module Config
      def acts_as_inkwell_user
        has_many :comments, :class_name => 'Inkwell::Comment'
        has_many :favorite_items, :class_name => 'Inkwell::FavoriteItem'
        has_many :timeline_items, :class_name => 'Inkwell::TimelineItem'
        include ::Inkwell::ActsAsInkwellUser::InstanceMethods
        include ::Inkwell::Common
      end
    end

    module InstanceMethods
      def blogline(options = {})
        options.symbolize_keys!
        last_shown_obj_id = options[:last_shown_obj_id]
        limit = options[:limit] || 10
        for_user = options[:for_user]

        if last_shown_obj_id
          blog_items = ::Inkwell::BlogItem.where(:owner_id => self.id, :is_owner_user => true).where("created_at < ?", Inkwell::BlogItem.find(last_shown_obj_id).created_at).order("created_at DESC").limit(limit)
        else
          blog_items = ::Inkwell::BlogItem.where(:owner_id => self.id, :is_owner_user => true).order("created_at DESC").limit(limit)
        end

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        result = []
        blog_items.each do |item|
          if item.is_comment
            blog_obj = ::Inkwell::Comment.find item.item_id
          else
            blog_obj = post_class.find item.item_id
          end

          blog_obj.item_id_in_line = item.id
          blog_obj.is_reblog_in_blogline = item.is_reblog

          if for_user
            blog_obj.is_reblogged = for_user.reblog? blog_obj
            blog_obj.is_favorited = for_user.favorite? blog_obj
          end

          result << blog_obj
        end
        result
      end

      def communities_row
        ActiveSupport::JSON.decode self.communities_ids
      end

      def favorite(obj)
        return if self.favorite? obj

        FavoriteItem.create :item_id => obj.id, :user_id => self.id, :is_comment => is_comment(obj)

        users_ids_who_favorite_it = ActiveSupport::JSON.decode obj.users_ids_who_favorite_it
        users_ids_who_favorite_it << self.id
        obj.users_ids_who_favorite_it = ActiveSupport::JSON.encode users_ids_who_favorite_it
        obj.save
      end

      def favorite?(obj)
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        (FavoriteItem.send("find_by_item_id_and_is_comment_and_#{user_id_attr}", obj.id, is_comment(obj), self.id)) ? true : false
      end

      def unfavorite(obj)
        return unless self.favorite? obj

        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        record = FavoriteItem.send "find_by_item_id_and_is_comment_and_#{user_id_attr}", obj.id, is_comment(obj), self.id
        record.destroy

        users_ids_who_favorite_it = ActiveSupport::JSON.decode obj.users_ids_who_favorite_it
        users_ids_who_favorite_it.delete self.id
        obj.users_ids_who_favorite_it = ActiveSupport::JSON.encode users_ids_who_favorite_it
        obj.save
      end

      def favoriteline(options = {})
        options.symbolize_keys!
        last_shown_obj_id = options[:last_shown_obj_id]
        limit = options[:limit] || 10
        for_user = options[:for_user]

        if last_shown_obj_id
          favorites = self.favorite_items.where("created_at < ?", Inkwell::FavoriteItem.find(last_shown_obj_id).created_at).order("created_at DESC").limit(limit)
        else
          favorites = self.favorite_items.order("created_at DESC").limit(limit)
        end

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        result = []
        favorites.each do |item|
          if item.is_comment
            favorited_obj = ::Inkwell::Comment.find item.item_id
          else
            favorited_obj = post_class.find item.item_id
          end

          favorited_obj.item_id_in_line = item.id

          if for_user
            favorited_obj.is_reblogged = for_user.reblog? favorited_obj
            favorited_obj.is_favorited = for_user.favorite? favorited_obj
          end

          result << favorited_obj
        end
        result
      end

      def follow(user)
        return if self.follow? user
        raise "User tries to follow himself." if self == user

        followers = ActiveSupport::JSON.decode user.followers_ids
        followers = followers << self.id
        user.followers_ids = ActiveSupport::JSON.encode followers
        user.save

        followings = ActiveSupport::JSON.decode self.followings_ids
        followings << user.id
        self.followings_ids = ActiveSupport::JSON.encode followings
        self.save

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        ::Inkwell::BlogItem.where(:owner_id => user.id, :is_owner_user => true).order("created_at DESC").limit(10).each do |blog_item|
          if blog_item.is_reblog
            item_class = blog_item.is_comment? ? ::Inkwell::Comment : post_class
            next if item_class.find(blog_item.item_id).send(user_id_attr) == self.id
          end

          item = ::Inkwell::TimelineItem.send "find_by_item_id_and_#{user_id_attr}_and_is_comment", blog_item.item_id, self.id, blog_item.is_comment
          if item
            item.has_many_sources = true unless item.has_many_sources
            sources = ActiveSupport::JSON.decode item.from_source
            if blog_item.is_reblog
              sources << Hash['user_id' => user.id, 'type' => 'reblog']
            else
              sources << Hash['user_id' => user.id, 'type' => 'following']
            end
            item.from_source = ActiveSupport::JSON.encode sources
            item.save
          else
            sources = []
            if blog_item.is_reblog
              sources << Hash['user_id' => user.id, 'type' => 'reblog']
            else
              sources << Hash['user_id' => user.id, 'type' => 'following']
            end
            ::Inkwell::TimelineItem.create :item_id => blog_item.item_id, :is_comment => blog_item.is_comment, :user_id => self.id,
                                           :from_source => ActiveSupport::JSON.encode(sources), :created_at => blog_item.created_at
          end
        end
      end

      def unfollow(user)
        return unless self.follow? user
        raise "User tries to unfollow himself." if self == user

        followers = ActiveSupport::JSON.decode user.followers_ids
        followers.delete self.id
        user.followers_ids = ActiveSupport::JSON.encode followers
        user.save

        followings = ActiveSupport::JSON.decode self.followings_ids
        followings.delete user.id
        self.followings_ids = ActiveSupport::JSON.encode followings
        self.save

        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"

        timeline_items = ::Inkwell::TimelineItem.where "from_source like '%{\"user_id\":#{user.id}%' and #{user_id_attr} = #{self.id}"
        timeline_items.delete_all :has_many_sources => false
        timeline_items.each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete_if { |rec| rec['user_id'] == user.id }
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end
      end

      def follow?(user)
        followings = ActiveSupport::JSON.decode self.followings_ids
        followings.include? user.id
      end

      def followers_row
        ActiveSupport::JSON.decode self.followers_ids
      end

      def followings_row
        ActiveSupport::JSON.decode self.followings_ids
      end

      def reblog(obj)
        return if self.reblog? obj
        raise "User tries to reblog his post." if self.id == obj.user_id

        is_comment = is_comment(obj)

        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        BlogItem.create :item_id => obj.id, :is_reblog => true, :owner_id => self.id, :is_owner_user => true, :is_comment => is_comment

        users_ids_who_reblog_it = ActiveSupport::JSON.decode obj.users_ids_who_reblog_it
        users_ids_who_reblog_it << self.id
        obj.users_ids_who_reblog_it = ActiveSupport::JSON.encode users_ids_who_reblog_it
        obj.save

        self.followers_row.each do |user_id|
          next if obj.send(user_id_attr) == user_id
          item = TimelineItem.send "find_by_item_id_and_#{user_id_attr}_and_is_comment", obj.id, user_id, is_comment
          if item
            item.has_many_sources = true unless item.has_many_sources
            sources = ActiveSupport::JSON.decode item.from_source
            sources << Hash['user_id' => self.id, 'type' => 'reblog']
            item.from_source = ActiveSupport::JSON.encode sources
            item.save
          else
            encode_sources = ActiveSupport::JSON.encode [Hash['user_id' => self.id, 'type' => 'reblog']]
            TimelineItem.create :item_id => obj.id, :created_at => obj.created_at, user_id_attr => user_id, :from_source => encode_sources, :is_comment => is_comment
          end
        end
      end

      def reblog?(obj)
        BlogItem.exists? :item_id => obj.id, :owner_id => self.id, :is_owner_user => true, :is_reblog => true, :is_comment => is_comment(obj)
      end

      def unreblog(obj)
        return unless self.reblog? obj
        raise "User tries to unreblog his post." if self.id == obj.user_id

        is_comment = is_comment(obj)

        users_ids_who_reblog_it = ActiveSupport::JSON.decode obj.users_ids_who_reblog_it
        users_ids_who_reblog_it.delete self.id
        obj.users_ids_who_reblog_it = ActiveSupport::JSON.encode users_ids_who_reblog_it
        obj.save

        ::Inkwell::BlogItem.delete_all :owner_id => self.id, :is_owner_user => true, :item_id => obj.id, :is_reblog => true, :is_comment => is_comment

        TimelineItem.delete_all :user_id => self.followers_row, :has_many_sources => false, :item_id => obj.id, :is_comment => is_comment
        TimelineItem.where(:user_id => self.followers_row, :item_id => obj.id, :is_comment => is_comment).each do |item|
            sources = ActiveSupport::JSON.decode item.from_source
            sources.delete Hash['user_id' => self.id, 'type' => 'reblog']
            item.has_many_sources = false if sources.size < 2
            item.from_source = ActiveSupport::JSON.encode sources
            item.save
        end
      end

      def timeline(options = {})
        options.symbolize_keys!
        last_shown_obj_id = options[:last_shown_obj_id]
        limit = options[:limit] || 10
        for_user = options[:for_user]

        if last_shown_obj_id
          timeline_items = self.timeline_items.where("created_at < ?", Inkwell::TimelineItem.find(last_shown_obj_id).created_at).order("created_at DESC").limit(limit)
        else
          timeline_items = self.timeline_items.order("created_at DESC").limit(limit)
        end

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        result = []
        timeline_items.each do |item|
          if item.is_comment
            timeline_obj = ::Inkwell::Comment.find item.item_id
          else
            timeline_obj = post_class.find item.item_id
          end

          timeline_obj.item_id_in_line = item.id
          timeline_obj.from_sources_in_timeline = item.from_source

          if for_user
            timeline_obj.is_reblogged = for_user.reblog? timeline_obj
            timeline_obj.is_favorited = for_user.favorite? timeline_obj
          end

          result << timeline_obj
        end
        result
      end

      #wrappers for community methods

      def join(open_community)
        open_community.add_user :user => self
      end

      def leave(community)
        community.remove_user :user => self
      end

      def kick(options = {})
        options.symbolize_keys!
        from_community = options[:from_community]
        user = options[:user]
        from_community.remove_user :user => user, :admin => self
      end

      def send_post_to_community(options = {})
        options.symbolize_keys!
        to_community = options[:to_community]
        post = options[:post]
        to_community.add_post :post => post, :user => self
      end

      def remove_post_from_community(options = {})
        options.symbolize_keys!
        from_community = options[:from_community]
        post = options[:post]
        from_community.remove_post :post => post, :user => self
      end

      def grant_admin_permissions(options = {})
        options.symbolize_keys!
        to_user = options[:to_user]
        in_community = options[:in_community]
        in_community.add_admin(:user => to_user, :admin => self)
      end

      def revoke_admin_permissions(options = {})
        options.symbolize_keys!
        user = options[:user]
        in_community = options[:in_community]
        in_community.remove_admin(:user => user, :admin => self)
      end

    end
  end
end

::ActiveRecord::Base.send :include, ::Inkwell::ActsAsInkwellUser::Base