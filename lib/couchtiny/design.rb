require 'digest/md5'
require 'couchtiny/delegate_doc'
require 'couchtiny/utils'

module CouchTiny
  # This class wraps a hash containing a Design document. It calculates
  # an id based on the contents, so that if the design doc changes, it is
  # stored under a new name.
  #
  # TODO: allow other uses of design doc, like update validation

  class Design < DelegateDoc
    attr_accessor :default_view_opts, :name_prefix, :with_slug
    include CouchTiny::Utils

    def self.default_doc
      {'language'=>'javascript'}
    end
    
    def initialize(name = "", with_slug = false, doc = self.class.default_doc)
      super(doc)
      @name_prefix = name
      @with_slug = with_slug || name.empty?
      @default_view_opts = {}
      changed
    end

    # Force recalculation of the slug
    def changed
      @slug = nil
    end

    def slug
      @slug ||= calc_slug(doc)
    end

    def calc_slug(doc)
      md5 = Digest::MD5.new
      doc['views'].sort.each do |k,v|
        md5 << "#{k}/#{v['map']}#{v['reduce']}"
      end if doc['views']
      md5.hexdigest
    end
    private :calc_slug

    def name
      @with_slug ? "#{name_prefix}#{slug}" : name_prefix
    end

    def id
      "_design/#{name}"
    end
    
    # Define a view:
    #   define_view "name", "map fn", [default opts]
    #   define_view "name", "map fn", "reduce fn", [default opts]
    # Any default options provided are used when invoking the view.
    # For example, you can define a reduce function but apply :reduce=>false
    # as an option, so that the reduce is only invoked when explicitly requested.
    def define_view(vname, map, *args)
      vname = vname.to_s
      opt = args.pop if args.last.instance_of?(Hash)
      default_view_opts[vname] = opt || {}
      doc['views'] ||= {}
      doc['views'][vname] ||= {}
      doc['views'][vname]['map'] = map
      if args[0]
        doc['views'][vname]['reduce'] = args[0]
      else
        doc['views'][vname].delete('reduce')
      end
      changed
    end
    
    # Fetch a view using this design document on a specific database
    # instance. Creates the design document if it does not exist.
    def view_on(db, vname, opt={}, &blk) #:yields: row
      opt = default_view_opts[vname.to_s].merge(opt)
      opt.delete(:include_docs) if opt[:reduce] && !opt[:include_docs] # COUCHDB-331
      db.view(name, vname, opt.dup, &blk)
    rescue  # TODO: only "resource not found" type errors
      # Note that you'll also get a 404 if the design doc exists but the view
      # name was wrong. In that case the second view call will fail.
      update_on(db)
      db.view(name, vname, opt, &blk)
    end

    # Check that the design doc is up to date on the given database,
    # and if not, save it. (Useful when *not* using slugs in design doc names)
    def update_on(db)
      begin
        prev = db.get(id)
        if slug != calc_slug(prev)
          db._put(id, doc.merge('_rev'=>prev['_rev']))
        end
      rescue RestClient::ResourceNotFound
        db._put(id, doc)
      end
    end
    
    # A null reduce function allows you to perform grouped queries
    REDUCE_NULL = <<REDUCE.freeze
function(ks, vs, co) {
  return null;
}
REDUCE
    # A useful generic reduce function for counting objects. Returns a Number.
    REDUCE_COUNT = <<REDUCE.freeze
function(ks, vs, co) {
  if (co) {
    return sum(vs);
  } else {
    return vs.length;
  }
}
REDUCE

    # A reduce optimised for low-cardinality string values. Returns an
    # Object which maps each value to its count.
    REDUCE_LOW_CARDINALITY = <<REDUCE.freeze
function(ks, vs, co) {
  if (co) {
    var result = vs.shift();
    for (var i in vs) {
      for (var j in vs[i]) {
        result[j] = (result[j] || 0) + vs[i][j];
      }
    }
    return result;
  } else {
    var result = {};
    for (var i in ks) {
      var key = ks[i];
      result[key[0]] = (result[key[0]] || 0) + 1;
    }
    return result;
  }
}
REDUCE
  end
end
