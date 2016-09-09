require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

require 'dbm'
require 'pp'

f = Faraday.new(url: 'https://queue.taskcluster.net')

# This is used to relay events to the eventsource
all_failed = Queue.new

Bunny.new(host: 'pulse.mozilla.org',
          port: 5671,
          user: ENV['PULSE_USER'],
          pass: ENV['PULSE_PASS'],
          vhost: '/',
          ssl: true,
          verify_peer: false).tap do |conn|

  conn.start

  channel = conn.create_channel
  exchange = channel.topic('exchange/taskcluster-queue/v1/task-failed', passive: true)
  am_queue = channel.queue("queue/#{ENV['PULSE_USER']}/myqueue", auto_delete: true).bind(exchange, routing_key: '#')

  # This launches in a new thread
  am_queue.subscribe do |delivery_info, metadata, json|
    event_data = MultiJson.load(json)
    response = f.get("/v1/task/#{event_data['status']['taskId']}")
    task_data = MultiJson.load(response.body)
    all_failed << [event_data, task_data]
  end
end

token = ENV['TELEGRAM_KEY']
chats = DBM.new('chats')

Thread.new do
  while pair = all_failed.pop
    event,task = pair
    metadata = task['metadata']

    next unless metadata['name'].match(/(mulet|device)/i)

    Telegram::Bot::Client.run(token) do |bot|
      chats.each_key do |chat_id|
        begin
          # Telegram's markdown formatter isn't very good.
          name = task['metadata']['name'].gsub(/[\[\]()]/, ' ')
          text = "Taskcluster task [#{name}](https://tools.taskcluster.net/task-inspector/##{event['status']['taskId']}) (#{task['metadata']['description']}) failed."

          bot.api.send_message chat_id: chat_id.to_i,
                               text: text,
                               parse_mode: "Markdown"
        rescue => e
          p e
        end
      end
    end
  end
end

Telegram::Bot::Client.run(token) do |bot|
  bot.listen do |message|
    begin
      case message.text
      when '/start'
        chats[message.chat.id.to_s] = 1 unless chats.key? message.chat.id.to_s
        bot.api.send_message chat_id: message.chat.id,
                             text: 'started'

      when '/stop'
        chats.delete message.chat.id.to_s
        bot.api.send_message chat_id: message.chat.id,
                             text: 'stopped'

      when '/status'
        if chats.key? message.chat.id.to_s
          bot.api.send_message chat_id: message.chat.id,
                               text: 'Listening for failed tasks ...'
        else
          bot.api.send_message chat_id: message.chat.id,
                               text: 'Not listening. Use /start to make me listen for tasks'
        end
      end
    rescue Telegram::Bot::Exceptions::ResponseError => e
      p e
    end
  end
end


