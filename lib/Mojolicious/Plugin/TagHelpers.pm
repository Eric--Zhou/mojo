package Mojolicious::Plugin::TagHelpers;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::ByteStream;
use Mojo::Util 'xss_escape';
use Scalar::Util 'blessed';

sub register {
  my ($self, $app) = @_;

  # Text field variations
  my @time = qw(date datetime month time week);
  for my $name (@time, qw(color email number range search tel text url)) {
    $app->helper("${name}_field" => sub { _input(@_, type => $name) });
  }

  $app->helper(check_box =>
      sub { _input(shift, shift, value => shift, @_, type => 'checkbox') });
  $app->helper(csrf_field => \&_csrf_field);
  $app->helper(file_field =>
      sub { shift; _tag('input', name => shift, @_, type => 'file') });

  $app->helper(form_for     => \&_form_for);
  $app->helper(hidden_field => \&_hidden_field);
  $app->helper(image => sub { _tag('img', src => shift->url_for(shift), @_) });
  $app->helper(input_tag => sub { _input(@_) });
  $app->helper(javascript => \&_javascript);
  $app->helper(label_for  => \&_label_for);
  $app->helper(link_to    => \&_link_to);

  $app->helper(password_field => \&_password_field);
  $app->helper(radio_button =>
      sub { _input(shift, shift, value => shift, @_, type => 'radio') });

  $app->helper(select_field  => \&_select_field);
  $app->helper(stylesheet    => \&_stylesheet);
  $app->helper(submit_button => \&_submit_button);

  # "t" is just a shortcut for the "tag" helper
  $app->helper($_ => sub { shift; _tag(@_) }) for qw(t tag);

  $app->helper(tag_with_error => \&_tag_with_error);
  $app->helper(text_area      => \&_text_area);
}

sub _csrf_field {
  my $c = shift;
  return _hidden_field($c, csrf_token => $c->helpers->csrf_token, @_);
}

sub _form_for {
  my ($c, @url) = (shift, shift);
  push @url, shift if ref $_[0] eq 'HASH';

  # POST detection
  my @post;
  if (my $r = $c->app->routes->lookup($url[0])) {
    my %methods = (GET => 1, POST => 1);
    do {
      my @via = @{$r->via || []};
      %methods = map { $_ => 1 } grep { $methods{$_} } @via if @via;
    } while $r = $r->parent;
    @post = (method => 'POST') if $methods{POST} && !$methods{GET};
  }

  return _tag('form', action => $c->url_for(@url), @post, @_);
}

sub _hidden_field {
  my $c = shift;
  return _tag('input', name => shift, value => shift, @_, type => 'hidden');
}

sub _input {
  my ($c, $name) = (shift, shift);
  my %attrs = @_ % 2 ? (value => shift, @_) : @_;

  # Special selection value
  my @values = @{$c->every_param($name)};
  my $type = $attrs{type} || '';
  if (@values && $type ne 'submit') {

    # Checkbox or radiobutton
    my $value = $attrs{value} // '';
    if ($type eq 'checkbox' || $type eq 'radio') {
      $attrs{value} = $value;
      $attrs{checked} = 'checked' if grep { $_ eq $value } @values;
    }

    # Others
    else { $attrs{value} = $values[0] }
  }

  return _validation($c, $name, 'input', %attrs, name => $name);
}

sub _javascript {
  my $c = shift;

  # CDATA
  my $cb = sub {''};
  if (ref $_[-1] eq 'CODE' && (my $old = pop)) {
    $cb = sub { "//<![CDATA[\n" . $old->() . "\n//]]>" }
  }

  # URL
  my $src = @_ % 2 ? $c->url_for(shift) : undef;

  return _tag('script', @_, $src ? (src => $src) : (), $cb);
}

sub _label_for {
  my ($c, $name) = (shift, shift);
  my $content = ref $_[-1] eq 'CODE' ? pop : shift;
  return _validation($c, $name, 'label', for => $name, @_, $content);
}

sub _link_to {
  my ($c, $content) = (shift, shift);
  my @url = ($content);

  # Content
  unless (ref $_[-1] eq 'CODE') {
    @url = (shift);
    push @_, $content;
  }

  # Captures
  push @url, shift if ref $_[0] eq 'HASH';

  return _tag('a', href => $c->url_for(@url), @_);
}

sub _option {
  my ($values, $pair) = @_;
  $pair = [$pair => $pair] unless ref $pair eq 'ARRAY';

  # Attributes
  my %attrs = (value => $pair->[1]);
  $attrs{selected} = 'selected' if exists $values->{$pair->[1]};
  %attrs = (%attrs, @$pair[2 .. $#$pair]);

  return _tag('option', %attrs, $pair->[0]);
}

sub _password_field {
  my ($c, $name) = (shift, shift);
  return _validation($c, $name, 'input', @_, name => $name,
    type => 'password');
}

sub _select_field {
  my ($c, $name, $options, %attrs) = (shift, shift, shift, @_);

  my %values = map { $_ => 1 } @{$c->every_param($name)};

  my $groups = '';
  for my $group (@$options) {

    # "optgroup" tag
    if (blessed $group && $group->isa('Mojo::Collection')) {
      my ($label, $values, %attrs) = @$group;
      my $content = join '', map { _option(\%values, $_) } @$values;
      $groups .= _tag('optgroup', label => $label, %attrs, sub {$content});
    }

    # "option" tag
    else { $groups .= _option(\%values, $group) }
  }

  return _validation($c, $name, 'select', %attrs, name => $name,
    sub {$groups});
}

sub _stylesheet {
  my $c = shift;

  # CDATA
  my $cb;
  if (ref $_[-1] eq 'CODE' && (my $old = pop)) {
    $cb = sub { "/*<![CDATA[*/\n" . $old->() . "\n/*]]>*/" }
  }

  # "link" or "style" tag
  my $href = @_ % 2 ? $c->url_for(shift) : undef;
  return $href
    ? _tag('link', rel => 'stylesheet', href => $href, @_)
    : _tag('style', @_, $cb);
}

sub _submit_button {
  my $c = shift;
  return _tag('input', value => shift // 'Ok', @_, type => 'submit');
}

sub _tag {
  my $name = shift;

  # Content
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $content = @_ % 2 ? pop : undef;

  # Start tag
  my $tag = "<$name";

  # Attributes
  my %attrs = @_;
  if ($attrs{data} && ref $attrs{data} eq 'HASH') {
    while (my ($key, $value) = each %{$attrs{data}}) {
      $key =~ y/_/-/;
      $attrs{lc("data-$key")} = $value;
    }
    delete $attrs{data};
  }
  $tag .= qq{ $_="} . xss_escape($attrs{$_} // '') . '"' for sort keys %attrs;

  # Empty element
  unless ($cb || defined $content) { $tag .= ' />' }

  # End tag
  else { $tag .= '>' . ($cb ? $cb->() : xss_escape $content) . "</$name>" }

  # Prevent escaping
  return Mojo::ByteStream->new($tag);
}

sub _tag_with_error {
  my ($c, $tag) = (shift, shift);
  my ($content, %attrs) = (@_ % 2 ? pop : undef, @_);
  $attrs{class} .= $attrs{class} ? ' field-with-error' : 'field-with-error';
  return _tag($tag, %attrs, defined $content ? $content : ());
}

sub _text_area {
  my ($c, $name) = (shift, shift);

  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $content = @_ % 2 ? shift : undef;
  $content = $c->param($name) // $content // $cb // '';

  return _validation($c, $name, 'textarea', @_, name => $name, $content);
}

sub _validation {
  my ($c, $name) = (shift, shift);
  return _tag(@_) unless $c->validation->has_error($name);
  return $c->helpers->tag_with_error(@_);
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::TagHelpers - Tag helpers plugin

=head1 SYNOPSIS

  # Mojolicious
  $self->plugin('TagHelpers');

  # Mojolicious::Lite
  plugin 'TagHelpers';

=head1 DESCRIPTION

L<Mojolicious::Plugin::TagHelpers> is a collection of HTML tag helpers for
L<Mojolicious>.

Most form helpers can automatically pick up previous input values and will
show them as default. You can also use
L<Mojolicious::Plugin::DefaultHelpers/"param"> to set them manually and let
necessary attributes always be generated automatically.

  % param country => 'germany' unless param 'country';
  <%= radio_button country => 'germany' %> Germany
  <%= radio_button country => 'france'  %> France
  <%= radio_button country => 'uk'      %> UK

For fields that failed validation with L<Mojolicious::Controller/"validation">
the C<field-with-error> class will be automatically added through the
C<tag_with_error> helper, to make styling with CSS easier.

  <input class="field-with-error" name="age" type="text" value="250" />

This is a core plugin, that means it is always enabled and its code a good
example for learning how to build new plugins, you're welcome to fork it.

See L<Mojolicious::Plugins/"PLUGINS"> for a list of plugins that are available
by default.

=head1 HELPERS

L<Mojolicious::Plugin::TagHelpers> implements the following helpers.

=head2 check_box

  %= check_box employed => 1
  %= check_box employed => 1, disabled => 'disabled'

Generate C<input> tag of type C<checkbox>. Previous input values will
automatically get picked up and shown as default.

  <input name="employed" type="checkbox" value="1" />
  <input disabled="disabled" name="employed" type="checkbox" value="1" />

=head2 color_field

  %= color_field 'background'
  %= color_field background => '#ffffff'
  %= color_field background => '#ffffff', id => 'foo'

Generate C<input> tag of type C<color>. Previous input values will
automatically get picked up and shown as default.

  <input name="background" type="color" />
  <input name="background" type="color" value="#ffffff" />
  <input id="foo" name="background" type="color" value="#ffffff" />

=head2 csrf_field

  %= csrf_field

Generate C<input> tag of type C<hidden> with
L<Mojolicious::Plugin::DefaultHelpers/"csrf_token">.

  <input name="csrf_token" type="hidden" value="fa6a08..." />

=head2 date_field

  %= date_field 'end'
  %= date_field end => '2012-12-21'
  %= date_field end => '2012-12-21', id => 'foo'

Generate C<input> tag of type C<date>. Previous input values will
automatically get picked up and shown as default.

  <input name="end" type="date" />
  <input name="end" type="date" value="2012-12-21" />
  <input id="foo" name="end" type="date" value="2012-12-21" />

=head2 datetime_field

  %= datetime_field 'end'
  %= datetime_field end => '2012-12-21T23:59:59Z'
  %= datetime_field end => '2012-12-21T23:59:59Z', id => 'foo'

Generate C<input> tag of type C<datetime>. Previous input values will
automatically get picked up and shown as default.

  <input name="end" type="datetime" />
  <input name="end" type="datetime" value="2012-12-21T23:59:59Z" />
  <input id="foo" name="end" type="datetime" value="2012-12-21T23:59:59Z" />

=head2 email_field

  %= email_field 'notify'
  %= email_field notify => 'nospam@example.com'
  %= email_field notify => 'nospam@example.com', id => 'foo'

Generate C<input> tag of type C<email>. Previous input values will
automatically get picked up and shown as default.

  <input name="notify" type="email" />
  <input name="notify" type="email" value="nospam@example.com" />
  <input id="foo" name="notify" type="email" value="nospam@example.com" />

=head2 file_field

  %= file_field 'avatar'
  %= file_field 'avatar', id => 'foo'

Generate C<input> tag of type C<file>.

  <input name="avatar" type="file" />
  <input id="foo" name="avatar" type="file" />

=head2 form_for

  %= form_for login => begin
    %= text_field 'first_name'
    %= submit_button
  % end
  %= form_for login => {format => 'txt'} => (method => 'POST') => begin
    %= text_field 'first_name'
    %= submit_button
  % end
  %= form_for '/login' => (enctype => 'multipart/form-data') => begin
    %= text_field 'first_name', disabled => 'disabled'
    %= submit_button
  % end
  %= form_for 'http://example.com/login' => (method => 'POST') => begin
    %= text_field 'first_name'
    %= submit_button
  % end

Generate portable C<form> tag with L<Mojolicious::Controller/"url_for">. For
routes that allow C<POST> but not C<GET>, a C<method> attribute will be
automatically added.

  <form action="/path/to/login">
    <input name="first_name" type="text" />
    <input value="Ok" type="submit" />
  </form>
  <form action="/path/to/login.txt" method="POST">
    <input name="first_name" type="text" />
    <input value="Ok" type="submit" />
  </form>
  <form action="/path/to/login" enctype="multipart/form-data">
    <input disabled="disabled" name="first_name" type="text" />
    <input value="Ok" type="submit" />
  </form>
  <form action="http://example.com/login" method="POST">
    <input name="first_name" type="text" />
    <input value="Ok" type="submit" />
  </form>

=head2 hidden_field

  %= hidden_field foo => 'bar'
  %= hidden_field foo => 'bar', id => 'bar'

Generate C<input> tag of type C<hidden>.

  <input name="foo" type="hidden" value="bar" />
  <input id="bar" name="foo" type="hidden" value="bar" />

=head2 image

  %= image '/images/foo.png'
  %= image '/images/foo.png', alt => 'Foo'

Generate portable C<img> tag.

  <img src="/path/to/images/foo.png" />
  <img alt="Foo" src="/path/to/images/foo.png" />

=head2 input_tag

  %= input_tag 'first_name'
  %= input_tag first_name => 'Default name'
  %= input_tag 'employed', type => 'checkbox'

Generate C<input> tag. Previous input values will automatically get picked up
and shown as default.

  <input name="first_name" />
  <input name="first_name" value="Default name" />
  <input name="employed" type="checkbox" />

=head2 javascript

  %= javascript '/script.js'
  %= javascript begin
    var a = 'b';
  % end

Generate portable C<script> tag for JavaScript asset.

  <script src="/path/to/script.js" />
  <script><![CDATA[
    var a = 'b';
  ]]></script>

=head2 label_for

  %= label_for first_name => 'First name'
  %= label_for first_name => 'First name', class => 'user'
  %= label_for first_name => begin
    First name
  % end
  %= label_for first_name => (class => 'user') => begin
    First name
  % end

Generate C<label> tag.

  <label for="first_name">First name</label>
  <label class="user" for="first_name">First name</label>
  <label for="first_name">
    First name
  </label>
  <label class="user" for="first_name">
    First name
  </label>

=head2 link_to

  %= link_to Home => 'index'
  %= link_to Home => 'index' => {format => 'txt'} => (class => 'menu')
  %= link_to index => {format => 'txt'} => (class => 'menu') => begin
    Home
  % end
  %= link_to Contact => 'mailto:sri@example.com'
  <%= link_to index => begin %>Home<% end %>
  <%= link_to '/file.txt' => begin %>File<% end %>
  <%= link_to 'http://mojolicio.us' => begin %>Mojolicious<% end %>
  <%= link_to url_for->query(foo => 'bar')->to_abs => begin %>Retry<% end %>

Generate portable C<a> tag with L<Mojolicious::Controller/"url_for">, defaults
to using the capitalized link target as content.

  <a href="/path/to/index">Home</a>
  <a class="menu" href="/path/to/index.txt">Home</a>
  <a class="menu" href="/path/to/index.txt">
    Home
  </a>
  <a href="mailto:sri@example.com">Contact</a>
  <a href="/path/to/index">Home</a>
  <a href="/path/to/file.txt">File</a>
  <a href="http://mojolicio.us">Mojolicious</a>
  <a href="http://127.0.0.1:3000/current/path?foo=bar">Retry</a>

=head2 month_field

  %= month_field 'vacation'
  %= month_field vacation => '2012-12'
  %= month_field vacation => '2012-12', id => 'foo'

Generate C<input> tag of type C<month>. Previous input values will
automatically get picked up and shown as default.

  <input name="vacation" type="month" />
  <input name="vacation" type="month" value="2012-12" />
  <input id="foo" name="vacation" type="month" value="2012-12" />

=head2 number_field

  %= number_field 'age'
  %= number_field age => 25
  %= number_field age => 25, id => 'foo', min => 0, max => 200

Generate C<input> tag of type C<number>. Previous input values will
automatically get picked up and shown as default.

  <input name="age" type="number" />
  <input name="age" type="number" value="25" />
  <input id="foo" max="200" min="0" name="age" type="number" value="25" />

=head2 password_field

  %= password_field 'pass'
  %= password_field 'pass', id => 'foo'

Generate C<input> tag of type C<password>.

  <input name="pass" type="password" />
  <input id="foo" name="pass" type="password" />

=head2 radio_button

  %= radio_button country => 'germany'
  %= radio_button country => 'germany', id => 'foo'

Generate C<input> tag of type C<radio>. Previous input values will
automatically get picked up and shown as default.

  <input name="country" type="radio" value="germany" />
  <input id="foo" name="country" type="radio" value="germany" />

=head2 range_field

  %= range_field 'age'
  %= range_field age => 25
  %= range_field age => 25, id => 'foo', min => 0, max => 200

Generate C<input> tag of type C<range>. Previous input values will
automatically get picked up and shown as default.

  <input name="age" type="range" />
  <input name="age" type="range" value="25" />
  <input id="foo" max="200" min="200" name="age" type="range" value="25" />

=head2 search_field

  %= search_field 'q'
  %= search_field q => 'perl'
  %= search_field q => 'perl', id => 'foo'

Generate C<input> tag of type C<search>. Previous input values will
automatically get picked up and shown as default.

  <input name="q" type="search" />
  <input name="q" type="search" value="perl" />
  <input id="foo" name="q" type="search" value="perl" />

=head2 select_field

  %= select_field country => [qw(de en)]
  %= select_field country => [[Germany => 'de'], 'en'], id => 'eu'
  %= select_field country => [[Germany => 'de', disabled => 'disabled'], 'en']
  %= select_field country => [c(EU => [[Germany => 'de'], 'en'], id => 'eu')]
  %= select_field country => [c(EU => [qw(de en)]), c(Asia => [qw(cn jp)])]

Generate C<select> and C<option> tags from array references and C<optgroup>
tags from L<Mojo::Collection> objects. Previous input values will
automatically get picked up and shown as default.

  <select name="country">
    <option value="de">de</option>
    <option value="en">en</option>
  </select>
  <select id="eu" name="country">
    <option value="de">Germany</option>
    <option value="en">en</option>
  </select>
  <select name="country">
    <option disabled="disabled" value="de">Germany</option>
    <option value="en">en</option>
  </select>
  <select name="country">
    <optgroup id="eu" label="EU">
      <option value="de">Germany</option>
      <option value="en">en</option>
    </optgroup>
  </select>
  <select name="country">
    <optgroup label="EU">
      <option value="de">de</option>
      <option value="en">en</option>
    </optgroup>
    <optgroup label="Asia">
      <option value="cn">cn</option>
      <option value="jp">jp</option>
    </optgroup>
  </select>

=head2 stylesheet

  %= stylesheet '/foo.css'
  %= stylesheet begin
    body {color: #000}
  % end

Generate portable C<style> or C<link> tag for CSS asset.

  <link href="/path/to/foo.css" rel="stylesheet" />
  <style><![CDATA[
    body {color: #000}
  ]]></style>

=head2 submit_button

  %= submit_button
  %= submit_button 'Ok!', id => 'foo'

Generate C<input> tag of type C<submit>.

  <input type="submit" value="Ok" />
  <input id="foo" type="submit" value="Ok!" />

=head2 t

  %=t div => 'test & 123'

Alias for L</"tag">.

  <div>test &amp; 123</div>

=head2 tag

  %= tag 'div'
  %= tag 'div', id => 'foo'
  %= tag div => 'test & 123'
  %= tag div => (id => 'foo') => 'test & 123'
  %= tag div => (data => {my_id => 1, Name => 'test'}) => 'test & 123'
  %= tag div => begin
    test & 123
  % end
  <%= tag div => (id => 'foo') => begin %>test & 123<% end %>

HTML/XML tag generator.

  <div />
  <div id="foo" />
  <div>test &amp; 123</div>
  <div id="foo">test &amp; 123</div>
  <div data-my-id="1" data-name="test">test &amp; 123</div>
  <div>
    test & 123
  </div>
  <div id="foo">test & 123</div>

Very useful for reuse in more specific tag helpers.

  my $output = $c->tag('div');
  my $output = $c->tag('div', id => 'foo');
  my $output = $c->tag(div => '<p>This will be escaped</p>');
  my $output = $c->tag(div => sub { '<p>This will not be escaped</p>' });

Results are automatically wrapped in L<Mojo::ByteStream> objects to prevent
accidental double escaping in C<ep> templates.

=head2 tag_with_error

  %= tag_with_error 'input', class => 'foo'

Same as L</"tag">, but adds the class C<field-with-error>.

  <input class="foo field-with-error" />

=head2 tel_field

  %= tel_field 'work'
  %= tel_field work => '123456789'
  %= tel_field work => '123456789', id => 'foo'

Generate C<input> tag of type C<tel>. Previous input values will automatically
get picked up and shown as default.

  <input name="work" type="tel" />
  <input name="work" type="tel" value="123456789" />
  <input id="foo" name="work" type="tel" value="123456789" />

=head2 text_area

  %= text_area 'foo'
  %= text_area 'foo', cols => 40
  %= text_area foo => 'Default!', cols => 40
  %= text_area foo => (cols => 40) => begin
    Default!
  % end

Generate C<textarea> tag. Previous input values will automatically get picked
up and shown as default.

  <textarea name="foo"></textarea>
  <textarea cols="40" name="foo"></textarea>
  <textarea cols="40" name="foo">Default!</textarea>
  <textarea cols="40" name="foo">
    Default!
  </textarea>

=head2 text_field

  %= text_field 'first_name'
  %= text_field first_name => 'Default name'
  %= text_field first_name => 'Default name', class => 'user'

Generate C<input> tag of type C<text>. Previous input values will
automatically get picked up and shown as default.

  <input name="first_name" type="text" />
  <input name="first_name" type="text" value="Default name" />
  <input class="user" name="first_name" type="text" value="Default name" />

=head2 time_field

  %= time_field 'start'
  %= time_field start => '23:59:59'
  %= time_field start => '23:59:59', id => 'foo'

Generate C<input> tag of type C<time>. Previous input values will
automatically get picked up and shown as default.

  <input name="start" type="time" />
  <input name="start" type="time" value="23:59:59" />
  <input id="foo" name="start" type="time" value="23:59:59" />

=head2 url_field

  %= url_field 'address'
  %= url_field address => 'http://mojolicio.us'
  %= url_field address => 'http://mojolicio.us', id => 'foo'

Generate C<input> tag of type C<url>. Previous input values will automatically
get picked up and shown as default.

  <input name="address" type="url" />
  <input name="address" type="url" value="http://mojolicio.us" />
  <input id="foo" name="address" type="url" value="http://mojolicio.us" />

=head2 week_field

  %= week_field 'vacation'
  %= week_field vacation => '2012-W17'
  %= week_field vacation => '2012-W17', id => 'foo'

Generate C<input> tag of type C<week>. Previous input values will
automatically get picked up and shown as default.

  <input name="vacation" type="week" />
  <input name="vacation" type="week" value="2012-W17" />
  <input id="foo" name="vacation" type="week" value="2012-W17" />

=head1 METHODS

L<Mojolicious::Plugin::TagHelpers> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new);

Register helpers in L<Mojolicious> application.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
