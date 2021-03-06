$LOAD_PATH << 'lib'
require 'rubygems'
require 'email_vision'

describe "EmailVision" do
  let(:email){"#{rand(1111111)}.foo@justatest.com"}
  let(:random_value){rand(11111111111).to_s}
  let(:expired_token){'Duy-M5FktALawBJ7dZN94s6hLEgLGKXC_j7cCqlDUMXRGw2shqHYbR9Zud_19EBtFkSCbJ0ZmrZ_d0ieBqgR'}

  def error_with_status(status)
    # mock / stub did not work...
    $the_status = status
    http = ""
    def http.error?; true; end
    def http.body; "<status>#{$the_status}</status>"; end
    def http.code; 500; end
    Savon::HTTP::Error.new(http)
  end

  # updates need some time to finish on the server...
  def wait_for_job_to_finish
    client.wait_for_job_to_finish yield
  end

  def reset_email
    email = client.find(changeable_user[:member_id])[:email]
    wait_for_job_to_finish do
      client.update(:email_was => email, :email => changeable_user[:email])
    end
    email = client.find(changeable_user[:member_id])[:email]
    email.should == changeable_user[:email]
  end

  def steady_fields(hash)
    hash.reject{|k,v| [:datejoin, :dateunjoin, :custom26].include?(k) }
  end

  let(:config){YAML.load(File.read('spec/account.yml'))}
  let(:client){EmailVision.new(config)}
  let(:findable_user) do
    data = config[:findable_user]
    [:datejoin, :dateunjoin].each do |field|
      data[field] = DateTime.parse(data[field].to_s) if data[field]
    end
    data
  end
  let(:changeable_user){config[:changeable_user]}

  it "has a VERSION" do
    EmailVision::VERSION.should =~ /^\d+\.\d+\.\d+$/
  end

  it "can call more than one method" do
    first = client.find(findable_user[:email])
    first.should == client.find(findable_user[:email])
  end

  it "can reconnect when token is expired" do
    client.instance_variable_set('@token', expired_token)
    client.instance_variable_set('@token_requested', Time.now.to_i - EmailVision::SESSION_TIMEOUT - 10)
    client.find(findable_user[:email])[:email].should == findable_user[:email]
  end

  describe :find do
    it "can find by email" do
      response = client.find(findable_user[:email])
      steady_fields(response).should == steady_fields(findable_user)
    end

    it "can find by id" do
      response = client.find(findable_user[:member_id])
      steady_fields(response).should == steady_fields(findable_user)
    end

    it "can find first users of multiple that have the same email" do
      client.should_receive(:execute_by_email_or_id).and_return [{:attributes=>{:entry=>[{:key=>"xx",:value=>'yyy'}]}},{:attributes=>{:entry=>[{:key=>"xx",:value=>'zzz'}]}}]
      response = client.find('foo@bar.com')
      steady_fields(response).should == {:xx => 'yyy'}
    end

    it "is nil when nothing was found" do
      client.find('foo@bar.baz').should == nil
    end
  end

  describe 'error handling' do
    before do
      @connection = client.send(:connection)
      client.stub!(:connection).and_return @connection
    end

    it "retries if it failed due to session timeout" do
      error = error_with_status("CHECK_SESSION_FAILED")
      @connection.should_receive(:request).exactly(2).and_raise(error)
      lambda{
        client.find('aaaa')
      }.should raise_error#(error)
    end

    it "retries if it failed due to maximum request per session" do
      error = error_with_status("SESSION_RETRIEVING_FAILED")
      @connection.should_receive(:request).exactly(2).and_raise(error)
      lambda{
        client.find('aaaa')
      }.should raise_error#(error)
    end

    it "does not retry if it failed otherwise" do
      error = error_with_status("FOO_BAR")
      @connection.should_receive(:request).exactly(1).and_raise(error)
      lambda{
        client.find('aaaa')
      }.should raise_error#(error)
    end
  end

  describe :update do
    it "can update an attribute" do
      wait_for_job_to_finish do
        client.update(
          :email => changeable_user[:email],
          :firstname => random_value,
          :lastname => random_value
        )
      end

      data = client.find(changeable_user[:email])
      data[:firstname].should == random_value
      data[:lastname].should == random_value

      # it does not overwrite other attributes
      data[:country].should == changeable_user[:country]
    end

    it "can update a Time" do
      time = Time.now
      wait_for_job_to_finish do
        client.update(:email => changeable_user[:email], :dateofbirth => time)
      end
      data = client.find(changeable_user[:email])
      data[:dateofbirth].strftime('%s').to_i.should == time.to_i
    end

    it "can update a Date" do
      time = Date.new(2010, 5,1)
      wait_for_job_to_finish do
        client.update(:email => changeable_user[:email], :dateofbirth => time)
      end
      data = client.find(changeable_user[:email])
      data[:dateofbirth].strftime('%s').to_i.should == 1272664800
    end

    it "can remove dateunjoin" do
      pending
      wait_for_job_to_finish do
        client.unjoin(changeable_user[:email])
      end
      wait_for_job_to_finish do
        client.update(:email => changeable_user[:email], :dateunjoin => 'NULL')
      end
      data = client.find(changeable_user[:email])
      data[:dateunjoin].should == nil
    end
    
    it "returns a job id" do
      job_id = client.update(:email => changeable_user[:email], :firstname => random_value)
      client.job_status(job_id).should == 'Insert'
    end

    it "updates the email" do
      begin
        wait_for_job_to_finish do
          client.update(:email_was => changeable_user[:email], :email => email)
        end
        client.find(email)[:email].should == email
      ensure
        reset_email
      end
    end
  end

  describe :create_or_update do
    it "can create a record" do
      wait_for_job_to_finish do
        client.create_or_update(:email => email, :firstname => 'first-name')
      end
      data = client.find(email)
      data[:firstname].should == 'first-name'
    end

    it "can update a record" do
      wait_for_job_to_finish do
        client.create_or_update(:email => changeable_user[:email], :firstname => random_value)
      end
      data = client.find(changeable_user[:email])
      data[:firstname].should == random_value
    end
  end

  describe :create do
    it "can create a record" do
      wait_for_job_to_finish do
        client.create(:email => email, :firstname => 'first-name')
      end
      data = client.find(email)
      data[:firstname].should == 'first-name'
    end
  end

  describe :columns do
    it "can read them" do
      data = client.columns
      data[:dateunjoin].should == :date
    end
  end

  describe :unjoin do
    it "can unjoin a member" do
      wait_for_job_to_finish do
        client.unjoin(changeable_user[:email])
      end
      date = client.find(changeable_user[:email])[:dateunjoin]
      date.is_a?(DateTime).should == true
      Time.parse(date.to_s).should be_within(40).of(Time.now)
    end
  end

  describe :rejoin do
    it "can rejoin a member" do
      wait_for_job_to_finish do
        client.rejoin(changeable_user[:email])
      end
      date = client.find(changeable_user[:email])[:datejoin]
      date.is_a?(DateTime).should == true
      Time.parse(date.to_s).should be_within(40).of(Time.now)
    end
  end
end
