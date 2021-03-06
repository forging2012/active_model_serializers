require 'active_model/serializer/field'

module ActiveModel
  class Serializer
    # Holds all the meta-data about an association as it was specified in the
    # ActiveModel::Serializer class.
    #
    # @example
    #   class PostSerializer < ActiveModel::Serializer
    #     has_one :author, serializer: AuthorSerializer
    #     has_many :comments
    #     has_many :comments, key: :last_comments do
    #       object.comments.last(1)
    #     end
    #     has_many :secret_meta_data, if: :is_admin?
    #
    #     has_one :blog do |serializer|
    #       meta count: object.roles.count
    #       serializer.cached_blog
    #     end
    #
    #     private
    #
    #     def cached_blog
    #       cache_store.fetch("cached_blog:#{object.updated_at}") do
    #         Blog.find(object.blog_id)
    #       end
    #     end
    #
    #     def is_admin?
    #       current_user.admin?
    #     end
    #   end
    #
    #  Specifically, the association 'comments' is evaluated two different ways:
    #  1) as 'comments' and named 'comments'.
    #  2) as 'object.comments.last(1)' and named 'last_comments'.
    #
    #  PostSerializer._reflections #=>
    #    # [
    #    #   HasOneReflection.new(:author, serializer: AuthorSerializer),
    #    #   HasManyReflection.new(:comments)
    #    #   HasManyReflection.new(:comments, { key: :last_comments }, #<Block>)
    #    #   HasManyReflection.new(:secret_meta_data, { if: :is_admin? })
    #    # ]
    #
    # So you can inspect reflections in your Adapters.
    class Reflection < Field
      def initialize(*)
        super
        options[:links] = {}
        options[:include_data_setting] = Serializer.config.include_data_default
        options[:meta] = nil
      end

      # @api public
      # @example
      #   has_one :blog do
      #     include_data false
      #     link :self, 'a link'
      #     link :related, 'another link'
      #     link :self, '//example.com/link_author/relationships/bio'
      #     id = object.profile.id
      #     link :related do
      #       "//example.com/profiles/#{id}" if id != 123
      #     end
      #     link :related do
      #       ids = object.likes.map(&:id).join(',')
      #       href "//example.com/likes/#{ids}"
      #       meta ids: ids
      #     end
      #   end
      def link(name, value = nil, &block)
        options[:links][name] = block || value
        :nil
      end

      # @api public
      # @example
      #   has_one :blog do
      #     include_data false
      #     meta(id: object.blog.id)
      #     meta liked: object.likes.any?
      #     link :self do
      #       href object.blog.id.to_s
      #       meta(id: object.blog.id)
      #     end
      def meta(value = nil, &block)
        options[:meta] = block || value
        :nil
      end

      # @api public
      # @example
      #   has_one :blog do
      #     include_data false
      #     link :self, 'a link'
      #     link :related, 'another link'
      #   end
      #
      #   has_one :blog do
      #     include_data false
      #     link :self, 'a link'
      #     link :related, 'another link'
      #   end
      #
      #    belongs_to :reviewer do
      #      meta name: 'Dan Brown'
      #      include_data true
      #    end
      #
      #    has_many :tags, serializer: TagSerializer do
      #      link :self, '//example.com/link_author/relationships/tags'
      #      include_data :if_sideloaded
      #    end
      def include_data(value = true)
        options[:include_data_setting] = value
        :nil
      end

      # @param serializer [ActiveModel::Serializer]
      # @yield [ActiveModel::Serializer]
      # @return [:nil, associated resource or resource collection]
      def value(serializer, include_slice)
        @object = serializer.object
        @scope = serializer.scope

        block_value = instance_exec(serializer, &block) if block
        return unless include_data?(include_slice)

        if block && block_value != :nil
          block_value
        else
          serializer.read_attribute_for_serialization(name)
        end
      end

      # Build association. This method is used internally to
      # build serializer's association by its reflection.
      #
      # @param [Serializer] parent_serializer for given association
      # @param [Hash{Symbol => Object}] parent_serializer_options
      #
      # @example
      #    # Given the following serializer defined:
      #    class PostSerializer < ActiveModel::Serializer
      #      has_many :comments, serializer: CommentSummarySerializer
      #    end
      #
      #    # Then you instantiate your serializer
      #    post_serializer = PostSerializer.new(post, foo: 'bar') #
      #    # to build association for comments you need to get reflection
      #    comments_reflection = PostSerializer._reflections.detect { |r| r.name == :comments }
      #    # and #build_association
      #    comments_reflection.build_association(post_serializer, foo: 'bar')
      #
      # @api private
      def build_association(parent_serializer, parent_serializer_options, include_slice = {})
        reflection_options = options.dup

        # Pass the parent's namespace onto the child serializer
        reflection_options[:namespace] ||= parent_serializer_options[:namespace]

        association_value = value(parent_serializer, include_slice)
        serializer_class = parent_serializer.class.serializer_for(association_value, reflection_options)
        reflection_options[:include_data] = include_data?(include_slice)
        reflection_options[:links] = options[:links]
        reflection_options[:meta] = options[:meta]

        if serializer_class
          serializer = catch(:no_serializer) do
            serializer_class.new(
              association_value,
              serializer_options(parent_serializer, parent_serializer_options, reflection_options)
            )
          end
          if serializer.nil?
            reflection_options[:virtual_value] = association_value.try(:as_json) || association_value
          else
            reflection_options[:serializer] = serializer
          end
        elsif !association_value.nil? && !association_value.instance_of?(Object)
          reflection_options[:virtual_value] = association_value
        end

        block = nil
        Association.new(name, reflection_options, block)
      end

      protected

      # used in instance exec
      attr_accessor :object, :scope

      private

      def include_data?(include_slice)
        include_data_setting = options[:include_data_setting]
        case include_data_setting
        when :if_sideloaded then include_slice.key?(name)
        when true           then true
        when false          then false
        else fail ArgumentError, "Unknown include_data_setting '#{include_data_setting.inspect}'"
        end
      end

      def serializer_options(parent_serializer, parent_serializer_options, reflection_options)
        serializer = reflection_options.fetch(:serializer, nil)

        serializer_options = parent_serializer_options.except(:serializer)
        serializer_options[:serializer] = serializer if serializer
        serializer_options[:serializer_context_class] = parent_serializer.class
        serializer_options
      end
    end
  end
end
