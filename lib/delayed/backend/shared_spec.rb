require File.expand_path('../../../../spec/sample_jobs', __FILE__)

shared_examples_for 'a delayed_job backend' do
  def create_job(opts = {})
    described_class.create(opts.merge(:payload_object => SimpleJob.new))
  end

  before do
    Delayed::Worker.max_priority = nil
    Delayed::Worker.min_priority = nil
    Delayed::Worker.default_priority = 99
    SimpleJob.runs = 0
    described_class.delete_all
  end

  it "should set run_at automatically if not set" do
    described_class.create(:payload_object => ErrorJob.new ).run_at.should_not be_nil
  end

  it "should not set run_at automatically if already set" do
    later = described_class.db_time_now + 5.minutes
    job = described_class.create(:payload_object => ErrorJob.new, :run_at => later)
    job.run_at.should be_within(1).of(later)
  end

  describe "enqueue" do
    context "with a hash" do
      it "should raise ArgumentError when handler doesn't respond_to :perform" do
        lambda { described_class.enqueue(:payload_object => Object.new) }.should raise_error(ArgumentError)
      end

      it "should be able to set priority" do
        job = described_class.enqueue :payload_object => SimpleJob.new, :priority => 5
        job.priority.should == 5
      end

      it "should use default priority" do
        job = described_class.enqueue :payload_object => SimpleJob.new
        job.priority.should == 99
      end

      it "should be able to set run_at" do
        later = described_class.db_time_now + 5.minutes
        job = described_class.enqueue :payload_object => SimpleJob.new, :run_at => later
        job.run_at.should be_within(1).of(later)
      end
    end

    context "with multiple arguments" do
      it "should raise ArgumentError when handler doesn't respond_to :perform" do
        lambda { described_class.enqueue(Object.new) }.should raise_error(ArgumentError)
      end

      it "should increase count after enqueuing items" do
        described_class.enqueue SimpleJob.new
        described_class.count.should == 1
      end

      it "should be able to set priority" do
        @job = described_class.enqueue SimpleJob.new, 5
        @job.priority.should == 5
      end

      it "should use default priority when it is not set" do
        @job = described_class.enqueue SimpleJob.new
        @job.priority.should == 99
      end

      it "should be able to set run_at" do
        later = described_class.db_time_now + 5.minutes
        @job = described_class.enqueue SimpleJob.new, 5, later
        @job.run_at.should be_within(1).of(later)
      end

      it "should work with jobs in modules" do
        M::ModuleJob.runs = 0
        job = described_class.enqueue M::ModuleJob.new
        lambda { job.invoke_job }.should change { M::ModuleJob.runs }.from(0).to(1)
      end
    end
  end

  describe "callbacks" do
    before(:each) do
      CallbackJob.messages = []
    end

    %w(before success after).each do |callback|
      it "should call #{callback} with job" do
        job = described_class.enqueue(CallbackJob.new)
        job.payload_object.should_receive(callback).with(job)
        job.invoke_job
      end
    end

    it "should call before and after callbacks" do
      job = described_class.enqueue(CallbackJob.new)
      CallbackJob.messages.should == ["enqueue"]
      job.invoke_job
      CallbackJob.messages.should == ["enqueue", "before", "perform", "success", "after"]
    end

    it "should call the after callback with an error" do
      job = described_class.enqueue(CallbackJob.new)
      job.payload_object.should_receive(:perform).and_raise(RuntimeError.new("fail"))

      lambda { job.invoke_job }.should raise_error
      CallbackJob.messages.should == ["enqueue", "before", "error: RuntimeError", "after"]
    end

    it "should call error when before raises an error" do
      job = described_class.enqueue(CallbackJob.new)
      job.payload_object.should_receive(:before).and_raise(RuntimeError.new("fail"))
      lambda { job.invoke_job }.should raise_error(RuntimeError)
      CallbackJob.messages.should == ["enqueue", "error: RuntimeError", "after"]
    end
  end

  describe "payload_object" do
    it "should raise a DeserializationError when the job class is totally unknown" do
      job = described_class.new :handler => "--- !ruby/object:JobThatDoesNotExist {}"
      lambda { job.payload_object }.should raise_error(Delayed::DeserializationError)
    end

    it "should raise a DeserializationError when the job struct is totally unknown" do
      job = described_class.new :handler => "--- !ruby/struct:StructThatDoesNotExist {}"
      lambda { job.payload_object }.should raise_error(Delayed::DeserializationError)
    end

    it "should raise a DeserializationError when the YAML.load raises argument error" do
      job = described_class.find(create_job.id)
      YAML.should_receive(:load).and_raise(ArgumentError)
      lambda { job.payload_object }.should raise_error(Delayed::DeserializationError)
    end
  end

  describe "reserve" do
    it "should not reserve failed jobs" do
      create_job :attempts => 50, :failed_at => described_class.db_time_now
      described_class.reserve('worker', 1.second).should be_nil
    end

    it "should not reserve jobs scheduled for the future" do
      create_job :run_at => (described_class.db_time_now + 1.minute)
      described_class.reserve('worker', 4.hours).should be_nil
    end

    it "should lock the job so other workers can't reserve it" do
      job = create_job
      described_class.reserve('worker1', 4.hours).should == job
      described_class.reserve('worker2', 4.hours).should be_nil
    end

    it "should reserve open jobs" do
      job = create_job
      described_class.reserve('worker', 4.hours).should == job
    end

    it "should reserve expired jobs" do
      job = create_job(:locked_by => 'worker', :locked_at => described_class.db_time_now - 2.minutes)
      described_class.reserve('worker', 1.minute).should == job
    end

    it "should reserve own jobs" do
      job = create_job(:locked_by => 'worker', :locked_at => (described_class.db_time_now - 1.minutes))
      described_class.reserve('worker', 4.hours).should == job
    end

    context "when another worker is already performing a task" do
      before :each do
        @job = described_class.create :payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => described_class.db_time_now - 5.minutes
      end

      it "should not allow a second worker to get exclusive access" do
        described_class.reserve('worker2').should be_nil
      end

      it "should allow a second worker to get exclusive access if the timeout has passed" do
        described_class.reserve('worker2', 1.minute).should == @job
      end
    end
  end

  context "when another worker has worked on a task since the job was found to be available, it" do

    before :each do
      @job = described_class.create :payload_object => SimpleJob.new
      @job_copy_for_worker_2 = described_class.find(@job.id)
    end

    it "should not allow a second worker to get exclusive access if already successfully processed by worker1" do
      @job.destroy
      @job_copy_for_worker_2.lock_exclusively!(4.hours, 'worker2').should == false
    end

    it "should not allow a second worker to get exclusive access if failed to be processed by worker1 and run_at time is now in future (due to backing off behaviour)" do
      @job.update_attributes(:attempts => 1, :run_at => described_class.db_time_now + 1.day)
      @job_copy_for_worker_2.lock_exclusively!(4.hours, 'worker2').should == false
    end
  end

  context "#name" do
    it "should be the class name of the job that was enqueued" do
      described_class.create(:payload_object => ErrorJob.new ).name.should == 'ErrorJob'
    end

    it "should be the method that will be called if its a performable method object" do
      job = described_class.new(:payload_object => NamedJob.new)
      job.name.should == 'named_job'
    end

    it "should be the instance method that will be called if its a performable method object" do
      @job = Story.create(:text => "...").delay.save
      @job.name.should == 'Story#save'
    end
  end

  context "worker prioritization" do
    before(:each) do
      Delayed::Worker.max_priority = nil
      Delayed::Worker.min_priority = nil
    end

    it "should fetch jobs ordered by priority" do
      10.times { described_class.enqueue SimpleJob.new, rand(10) }
      jobs = described_class.find_available('worker', 10)
      jobs.size.should == 10
      jobs.each_cons(2) do |a, b|
        a.priority.should <= b.priority
      end
    end

    it "should only find jobs greater than or equal to min priority" do
      min = 5
      Delayed::Worker.min_priority = min
      10.times {|i| described_class.enqueue SimpleJob.new, i }
      jobs = described_class.find_available('worker', 10)
      jobs.each {|job| job.priority.should >= min}
    end

    it "should only find jobs less than or equal to max priority" do
      max = 5
      Delayed::Worker.max_priority = max
      10.times {|i| described_class.enqueue SimpleJob.new, i }
      jobs = described_class.find_available('worker', 10)
      jobs.each {|job| job.priority.should <= max}
    end
  end

  context "clear_locks!" do
    before do
      @job = create_job(:locked_by => 'worker', :locked_at => described_class.db_time_now)
    end

    it "should clear locks for the given worker" do
      described_class.clear_locks!('worker')
      described_class.find_available('worker2', 5, 1.minute).should include(@job)
    end

    it "should not clear locks for other workers" do
      described_class.clear_locks!('worker1')
      described_class.find_available('worker1', 5, 1.minute).should_not include(@job)
    end
  end

  context "unlock" do
    before do
      @job = create_job(:locked_by => 'worker', :locked_at => described_class.db_time_now)
    end

    it "should clear locks" do
      @job.unlock
      @job.locked_by.should be_nil
      @job.locked_at.should be_nil
    end
  end

  context "large handler" do
    before do
      text = "Lorem ipsum dolor sit amet. " * 1000
      @job = described_class.enqueue Delayed::PerformableMethod.new(text, :length, {})
    end

    it "should have an id" do
      @job.id.should_not be_nil
    end
  end

  describe "yaml serialization" do
    it "should reload changed attributes" do
      job = described_class.enqueue SimpleJob.new
      yaml = job.to_yaml
      job.priority = 99
      job.save
      YAML.load(yaml).priority.should == 99
    end

    it "should ignore destroyed records" do
      job = described_class.enqueue SimpleJob.new
      yaml = job.to_yaml
      job.destroy
      lambda { YAML.load(yaml).should be_nil }.should_not raise_error
    end
  end

  describe "worker integration" do
    before do
      Delayed::Job.delete_all

      @worker = Delayed::Worker.new(:max_priority => nil, :min_priority => nil, :quiet => true)

      SimpleJob.runs = 0
    end

    describe "running a job" do
      it "should fail after Worker.max_run_time" do
        begin
          old_max_run_time = Delayed::Worker.max_run_time
          Delayed::Worker.max_run_time = 1.second
          @job = Delayed::Job.create :payload_object => LongRunningJob.new
          @worker.run(@job)
          @job.reload.last_error.should =~ /expired/
          @job.attempts.should == 1
        ensure
          Delayed::Worker.max_run_time = old_max_run_time
        end
      end

    end

    describe "failed jobs" do
      before do
        # reset defaults
        Delayed::Worker.destroy_failed_jobs = true
        Delayed::Worker.max_attempts = 25

        @job = Delayed::Job.enqueue(ErrorJob.new)
      end

      it "should record last_error when destroy_failed_jobs = false, max_attempts = 1" do
        Delayed::Worker.destroy_failed_jobs = false
        Delayed::Worker.max_attempts = 1
        @worker.run(@job)
        @job.reload
        @job.last_error.should =~ /did not work/
        @job.attempts.should == 1
        @job.failed_at.should_not be_nil
      end

      it "should re-schedule jobs after failing" do
        @worker.run(@job)
        @job.reload
        @job.last_error.should =~ /did not work/
        @job.last_error.should =~ /sample_jobs.rb:\d+:in `perform'/
        @job.attempts.should == 1
        @job.run_at.should > Delayed::Job.db_time_now - 10.minutes
        @job.run_at.should < Delayed::Job.db_time_now + 10.minutes
      end

      it 'should re-schedule with handler provided time if present' do
        @job = Delayed::Job.enqueue(CustomRescheduleJob.new(99.minutes))
        @worker.run(@job)
        @job.reload

        (Delayed::Job.db_time_now + 99.minutes - @job.run_at).abs.should < 1
      end

      it "should not fail when the triggered error doesn't have a message" do
        error_with_nil_message = StandardError.new
        error_with_nil_message.stub!(:message).and_return nil
        @job.stub!(:invoke_job).and_raise error_with_nil_message
        lambda{@worker.run(@job)}.should_not raise_error
      end
    end

    context "reschedule" do
      before do
        @job = Delayed::Job.create :payload_object => SimpleJob.new
      end

      share_examples_for "any failure more than Worker.max_attempts times" do
        context "when the job's payload has a #failure hook" do
          before do
            @job = Delayed::Job.create :payload_object => OnPermanentFailureJob.new
            @job.payload_object.should respond_to :failure
          end

          it "should run that hook" do
            @job.payload_object.should_receive :failure
            Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
          end
        end

        context "when the job's payload has no #failure hook" do
          # It's a little tricky to test this in a straightforward way,
          # because putting a should_not_receive expectation on
          # @job.payload_object.failure makes that object
          # incorrectly return true to
          # payload_object.respond_to? :failure, which is what
          # reschedule uses to decide whether to call failure.
          # So instead, we just make sure that the payload_object as it
          # already stands doesn't respond_to? failure, then
          # shove it through the iterated reschedule loop and make sure we
          # don't get a NoMethodError (caused by calling that nonexistent
          # failure method).

          before do
            @job.payload_object.should_not respond_to(:failure)
          end

          it "should not try to run that hook" do
            lambda do
              Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
            end.should_not raise_exception(NoMethodError)
          end
        end
      end

      context "and we want to destroy jobs" do
        before do
          Delayed::Worker.destroy_failed_jobs = true
        end

        it_should_behave_like "any failure more than Worker.max_attempts times"

        it "should be destroyed if it failed more than Worker.max_attempts times" do
          @job.should_receive(:destroy)
          Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
        end

        it "should not be destroyed if failed fewer than Worker.max_attempts times" do
          @job.should_not_receive(:destroy)
          (Delayed::Worker.max_attempts - 1).times { @worker.reschedule(@job) }
        end
      end

      context "and we don't want to destroy jobs" do
        before do
          Delayed::Worker.destroy_failed_jobs = false
        end

        it_should_behave_like "any failure more than Worker.max_attempts times"

        it "should be failed if it failed more than Worker.max_attempts times" do
          @job.reload.failed_at.should == nil
          Delayed::Worker.max_attempts.times { @worker.reschedule(@job) }
          @job.reload.failed_at.should_not == nil
        end

        it "should not be failed if it failed fewer than Worker.max_attempts times" do
          (Delayed::Worker.max_attempts - 1).times { @worker.reschedule(@job) }
          @job.reload.failed_at.should == nil
        end
      end
    end
  end
end