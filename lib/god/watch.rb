module God
  
  class Watch < Base
    VALID_STATES = [:init, :up, :start, :restart]
    
    # config
    attr_accessor :name, :state, :start, :stop, :restart, :interval, :grace
    
    # api
    attr_accessor :behaviors, :metrics
    
    # internal
    attr_accessor :mutex
    
    # 
    def initialize(meddle)
      @meddle = meddle
            
      # no grace period by default
      self.grace = 0
      
      # the list of behaviors
      self.behaviors = []
      
      # the list of conditions for each action
      self.metrics = {:init => [],
                      :start => [],
                      :restart => [],
                      :up => []}
                         
      # mutex
      self.mutex = Mutex.new
    end
    
    def behavior(kind)
      # create the behavior
      begin
        b = Behavior.generate(kind)
      rescue NoSuchBehaviorError => e
        abort e.message
      end
      
      # send to block so config can set attributes
      yield(b) if block_given?
      
      # abort if the Behavior is invalid, the Behavior will have printed
      # out its own error messages by now
      abort unless b.valid?
      
      self.behaviors << b
    end
    
    ###########################################################################
    #
    # Advanced mode
    #
    ###########################################################################
    
    # Define a transition handler which consists of a set of conditions
    def transition(start_states, end_states)
      # convert to into canonical hash form
      canonical_end_states = canonical_hash_form(end_states)
      
      # for each start state do
      Array(start_states).each do |start_state|
        # validate start state
        unless VALID_STATES.include?(start_state)
          abort "Invalid state :#{start_state}. Must be one of the symbols #{VALID_STATES.map{|x| ":#{x}"}.join(', ')}"
        end
        
        # create a new metric to hold the watch, end states, and conditions
        m = Metric.new(self, canonical_end_states)
        
        # let the config file define some conditions on the metric
        yield(m)
        
        # record the metric
        self.metrics[start_state] << m
      end
    end
    
    ###########################################################################
    #
    # Simple mode
    #
    ###########################################################################
    
    def start_if
      self.transition(:up, :start) do |on|
        yield(on)
      end
    end
    
    def restart_if
      self.transition(:up, :restart) do |on|
        yield(on)
      end
    end
    
    ###########################################################################
    #
    # Lifecycle
    #
    ###########################################################################
        
    # Schedule all poll conditions and register all condition events
    def monitor
      # start monitoring at the first available of the init or up states
      p metrics
      if !self.metrics[:init].empty?
        self.move(:init)
      else
        self.move(:up)
      end
    end
    
    # Move from one state to another
    def move(to_state)
      puts "move '#{self.state}' to '#{to_state}'"
       
      # cleanup from current state
      if from_state = self.state
        self.metrics[from_state].each { |m| m.disable }
      end
      
      # perform action (if available)
      self.action(to_state)
      
      # move to new state
      self.metrics[to_state].each { |m| m.enable }
      
      # set state
      self.state = to_state
    end
    
    def action(a, c = nil)
      case a
      when :start
        puts self.start
        call_action(c, :start, self.start)
        sleep(self.grace)
      when :restart
        if self.restart
          puts self.restart
          call_action(c, :restart, self.restart)
        else
          action(:stop, c)
          action(:start, c)
        end
        sleep(self.grace)
      when :stop
        puts self.stop
        call_action(c, :stop, self.stop)
        sleep(self.grace)
      end      
    end
    
    def call_action(condition, action, command)
      # before
      before_items = self.behaviors
      before_items += [condition] if condition
      before_items.each { |b| b.send("before_#{action}") }
      
      # action
      if command.kind_of?(String)
        # string command
        system(command)
      else
        # lambda command
        command.call
      end
      
      # after
      after_items = self.behaviors
      after_items += [condition] if condition
      after_items.each { |b| b.send("after_#{action}") }
    end
    
    def canonical_hash_form(to)
      to.instance_of?(Symbol) ? {true => to} : to
    end
  end
  
end