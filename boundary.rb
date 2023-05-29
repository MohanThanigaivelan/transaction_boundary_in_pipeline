require 'pg'
require 'benchmark'
require 'byebug'
require 'rails'

class FutureResult
  attr_accessor :result , :pending , :lock, :skip_exception
  def initialize
    self.pending = true
    self.skip_exception = false
  end
  def set_result(result)
    self.result = result
    self.pending = false
  end
  def get_result
    return result unless pending
    loop do
      puts "Waiting for the result!!"
      unless pending
        break
      end
    end
    result
  end
end

@connection = PG.connect
@ddl_connection = PG.connect
@connection.enter_pipeline_mode
@lock =  Mutex.new
@piped_results = []
@output = []

def submit_query(seconds)
  @lock.synchronize do
    puts "Submitting query"
    @connection.send_query_params("Select * from users where (select true from pg_sleep(#{seconds}))", [])
    @connection.send_flush_request
    future = FutureResult.new
    @piped_results << future
    future
  end
end

def get_result
  loop do
    @connection.consume_input
    if @connection.is_busy
      puts "Result not available yet!!"
      next
    end
    @lock.synchronize do
      puts "Result available"
      result = @connection.get_result
      if [PG::PGRES_TUPLES_OK, PG::PGRES_COMMAND_OK].include?(result.try(:result_status))
        future = @piped_results.shift
        @output << future
        future.set_result(result)
        if @piped_results.empty?
          @connection.pipeline_sync
        end
      elsif [PG::PGRES_FATAL_ERROR].include?(result.try(:result_status))
        future = @piped_results.shift
        @output << future
        future.set_result(result)
        unless future.skip_exception
          raise "PG Exception"
        else
          @connection.pipeline_sync
        end
      elsif [PG::PGRES_PIPELINE_ABORTED].include?(result.try(:result_status))
        future = @piped_results.shift
        @output << future
        future.set_result(result)
        @connection.pipeline_sync
      end
      next
    end
  end
end

t1= Thread.new do
  Thread.current.abort_on_exception = true
  get_result
end

future_1 = submit_query(5)
future_2 = submit_query(2)
#future_2.skip_exception = true
future_3 = submit_query(1)
future_4 = submit_query(2)
time = Benchmark.measure do
  puts future_1.get_result
  # sleep(10)
  puts future_2.get_result.values
  puts future_3.get_result.values
  puts future_4.get_result.values
end
puts time.real * 1000

@output.each do |future|
  puts future.result.values
end

# t.join
t1.kill



# t = Thread.new do
#   Thread.current.abort_on_exception = true
#   time = Benchmark.measure do
#     @ddl_connection.query("ALTER TABLE USERS add column descriptions text")
#   end
#   puts time.real * 1000
# end